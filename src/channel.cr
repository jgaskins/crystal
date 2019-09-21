require "fiber"
require "crystal/spin_lock"

# A `Channel` enables concurrent communication between fibers.
#
# They allow communicating data between fibers without sharing memory and without having to worry about locks, semaphores or other special structures.
#
# ```
# channel = Channel(Int32).new
#
# spawn do
#   channel.send(0)
#   channel.send(1)
# end
#
# channel.receive # => 0
# channel.receive # => 1
# ```
class Channel(T)
  @lock = Crystal::SpinLock.new
  @queue : Deque(T)?

  module NotReady
    extend self
  end

  module SelectAction(S)
    abstract def execute : S | NotReady
    abstract def wait(context : SelectContext(S))
    abstract def unwait
    abstract def result : S
    abstract def lock_object_id
    abstract def lock
    abstract def unlock

    def create_context_and_wait(state_ptr)
      context = SelectContext.new(state_ptr, self)
      self.wait(context)
      context
    end
  end

  enum SelectState
    None   = 0
    Active = 1
    Done   = 2
  end

  private class SelectContext(S)
    @state : Pointer(Atomic(SelectState))
    property action : SelectAction(S)
    @activated = false

    def initialize(@state, @action : SelectAction(S))
    end

    def activated?
      @activated
    end

    def try_trigger : Bool
      _, succeed = @state.value.compare_and_set(SelectState::Active, SelectState::Done)
      if succeed
        @activated = true
      end
      succeed
    end
  end

  class Error < Exception
  end

  class ClosedError < Error
    def initialize(msg = "Channel is closed")
      super(msg)
    end
  end

  class ReceiveTimeoutError < Error
  end

  enum DeliveryState
    None
    Delivered
    Closed
  end

  def initialize(@capacity = 0, @receive_timeout : Time::Span? = nil)
    @closed = false
    @senders = Deque({Fiber, T, SelectContext(Nil)?}).new
    @receivers = Deque({Fiber, Pointer(T), Pointer(DeliveryState), SelectContext(T)?}).new
    if capacity > 0
      @queue = Deque(T).new(capacity)
    end
  end

  def close
    @closed = true

    @senders.each &.first.enqueue

    @receivers.each do |receiver|
      receiver[2].value = DeliveryState::Closed
      receiver[0].enqueue
    end

    @senders.clear
    @receivers.clear
    nil
  end

  def closed?
    @closed
  end

  def send(value : T)
    @lock.sync do
      raise_if_closed

      send_internal(value) do
        @senders << {Fiber.current, value, nil}
        @lock.unsync do
          Crystal::Scheduler.reschedule
        end
        raise_if_closed
      end

      self
    end
  end

  protected def send_internal(value : T)
    if receiver = dequeue_receiver
      receiver[1].value = value
      receiver[2].value = DeliveryState::Delivered
      receiver[0].enqueue
    elsif (queue = @queue) && queue.size < @capacity
      queue << value
    else
      yield
    end
  end

  # Receives a value from the channel.
  # If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.
  #
  # Raises `ClosedError` if the channel is closed or closes while waiting for receive.
  #
  # ```
  # channel = Channel(Int32).new
  # channel.send(1)
  # channel.receive # => 1
  # ```
  def receive
    receive_impl { raise ClosedError.new }
  end

  # Receives a value from the channel.
  # If there is a value waiting, it is returned immediately. Otherwise, this method blocks until a value is sent to the channel.
  #
  # Returns `nil` if the channel is closed or closes while waiting for receive.
  def receive?
    receive_impl { return nil }
  end

  def receive_impl
    @lock.sync do
      receive_internal do
        yield if @closed

        value = uninitialized T
        state = DeliveryState::None
        @receivers << {Fiber.current, pointerof(value), pointerof(state), nil}
        @lock.unsync do
          Crystal::Scheduler.reschedule
        end

        case state
        when DeliveryState::Delivered
          value
        when DeliveryState::Closed
          yield
        else
          raise ReceiveTimeoutError.new("#{inspect} timed out after waiting for #{@receive_timeout.inspect}")
        end
      end
    end
  end

  def receive_internal
    if (queue = @queue) && !queue.empty?
      deque_value = queue.shift
      if sender = dequeue_sender
        sender[0].enqueue
        queue << sender[1]
      end
      deque_value
    elsif sender = dequeue_sender
      sender[0].enqueue
      sender[1]
    else
      if timeout = @receive_timeout
        receive_fiber = Fiber.current
        spawn do
          sleep timeout.not_nil!
          receive_fiber.resume
        end
      end

      yield
    end
  end

  private def dequeue_receiver
    while receiver = @receivers.shift?
      if (select_context = receiver[3]) && !select_context.try_trigger
        next
      end

      break
    end

    receiver
  end

  private def dequeue_sender
    while sender = @senders.shift?
      if (select_context = sender[2]) && !select_context.try_trigger
        next
      end

      break
    end

    sender
  end

  def inspect(io : IO) : Nil
    to_s(io)
  end

  def pretty_print(pp)
    pp.text inspect
  end

  protected def wait_for_receive(value, state, context)
    @receivers << {Fiber.current, value, state, context}
  end

  protected def unwait_for_receive
    @receivers.delete_if { |r| r[0] == Fiber.current }
  end

  protected def wait_for_send(value, context)
    @senders << {Fiber.current, value, context}
  end

  protected def unwait_for_send
    @senders.delete_if { |r| r[0] == Fiber.current }
  end

  protected def raise_if_closed
    raise ClosedError.new if @closed
  end

  def self.receive_first(*channels)
    receive_first channels
  end

  def self.receive_first(channels : Tuple | Array)
    _, value = self.select(channels.map(&.receive_select_action))
    if value.is_a?(NotReady)
      raise "BUG: Channel.select returned not ready status"
    end

    value
  end

  def self.send_first(value, *channels)
    send_first value, channels
  end

  def self.send_first(value, channels : Tuple | Array)
    self.select(channels.map(&.send_select_action(value)))
    nil
  end

  def self.select(*ops : SelectAction)
    self.select ops
  end

  def self.select(ops : Indexable(SelectAction), has_else = false)
    # Sort the operations by the channel they contain
    # This is to avoid deadlocks between concurrent `select` calls
    ops_locks = ops
      .to_a
      .uniq(&.lock_object_id)
      .sort_by(&.lock_object_id)

    ops_locks.each &.lock

    ops.each_with_index do |op, index|
      ignore = false
      result = op.execute

      unless result.is_a?(NotReady)
        ops_locks.each &.unlock
        return index, result
      end
    end

    if has_else
      ops_locks.each &.unlock
      return ops.size, NotReady
    end

    state = Atomic(SelectState).new(SelectState::Active)
    contexts = ops.map &.create_context_and_wait(pointerof(state))

    ops_locks.each &.unlock
    Crystal::Scheduler.reschedule

    ops.each do |op|
      op.lock
      op.unwait
      op.unlock
    end

    contexts.each_with_index do |context, index|
      if context.activated?
        return index, context.action.result
      end
    end

    raise "BUG: Fiber was awaken from select but no action was activated"
  end

  # :nodoc:
  def send_select_action(value : T)
    SendAction.new(self, value)
  end

  # :nodoc:
  def receive_select_action
    ReceiveAction.new(self)
  end

  # :nodoc:
  class ReceiveAction(T)
    include SelectAction(T)
    property value : T
    property state : DeliveryState

    def initialize(@channel : Channel(T))
      @value = uninitialized T
      @state = DeliveryState::None
    end

    def execute : Channel::NotReady | T
      @channel.receive_internal { return NotReady }
    end

    def result : T
      @value
    end

    def wait(context : SelectContext(T))
      @channel.wait_for_receive(pointerof(@value), pointerof(@state), context)
    end

    def unwait
      @channel.unwait_for_receive
    end

    def lock_object_id
      @channel.object_id
    end

    def lock
      @channel.@lock.lock
    end

    def unlock
      @channel.@lock.unlock
    end
  end

  # :nodoc:
  class SendAction(T)
    include SelectAction(Nil)

    def initialize(@channel : Channel(T), @value : T)
    end

    def execute : Channel::NotReady?
      @channel.send_internal(@value) { return NotReady }
      nil
    end

    def result : Nil
      nil
    end

    def wait(context : SelectContext(Nil))
      @channel.wait_for_send(@value, context)
    end

    def unwait
      @channel.unwait_for_send
    end

    def lock_object_id
      @channel.object_id
    end

    def lock
      @channel.@lock.lock
    end

    def unlock
      @channel.@lock.unlock
    end
  end
end
