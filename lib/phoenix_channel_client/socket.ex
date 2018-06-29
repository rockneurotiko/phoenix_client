defmodule PhoenixChannelClient.Socket do
  require Logger

  @heartbeat_interval 30_000
  @reconnect_interval 60_000

  @callback handle_close(reply :: Tuple.t(), state :: map) ::
              {:noreply, state :: map}
              | {:stop, reason :: term, state :: map}

  defmacro __using__(opts) do
    quote do
      require Logger
      @otp_app Keyword.get(unquote(opts), :otp_app)
      unquote(socket())
    end
  end

  defp socket do
    quote unquote: false do
      use GenServer

      # alias PhoenixChannelClient.Push

      def start_link(opts \\ []) do
        opts =
          Application.get_env(@otp_app, __MODULE__, [])
          |> Keyword.merge(opts)

        GenServer.start_link(
          PhoenixChannelClient.Socket,
          {unquote(__MODULE__), opts},
          name: __MODULE__
        )
      end

      def push(pid, topic, event, payload) do
        GenServer.call(pid, {:push, topic, event, payload})
      end

      def channel_link(pid, channel, topic) do
        GenServer.call(pid, {:channel_link, channel, topic})
      end

      def channel_unlink(pid, channel, topic) do
        GenServer.call(pid, {:channel_unlink, channel, topic})
      end

      def handle_close(_reason, state) do
        {:noreply, state}
      end

      def init(opts) do
        {:ok, opts}
      end

      defoverridable handle_close: 2
    end
  end

  ## Callbacks

  def init({sender, opts}) do
    adapter = opts[:adapter] || PhoenixChannelClient.Adapters.WebsocketClient

    :crypto.start()
    :ssl.start()
    reconnect = Keyword.get(opts, :reconnect, true)
    url = Keyword.get(opts, :url, "")
    opts = Keyword.put_new(opts, :headers, [])
    heartbeat_interval = opts[:heartbeat_interval] || @heartbeat_interval
    reconnect_interval = opts[:reconnect_interval] || @reconnect_interval
    adapter_opts = Keyword.put(opts, :sender, self())

    send(self(), :connect)

    {:ok,
     %{
       sender: sender,
       opts: opts,
       url: url,
       params: Keyword.get(opts, :params, %{}),
       socket: nil,
       channels: [],
       reconnect: reconnect,
       reconnect_timer: nil,
       heartbeat_interval: heartbeat_interval,
       reconnect_interval: reconnect_interval,
       status: :disconnected,
       adapter: adapter,
       adapter_opts: adapter_opts,
       queue: :queue.new(),
       ref: 0
     }}
  end

  def handle_call({:push, topic, event, payload}, _from, state) do
    ref = state.ref + 1
    push = %{topic: topic, event: event, payload: payload, ref: to_string(ref)}
    send(self(), :flush)
    {:reply, push, %{state | ref: ref, queue: :queue.in(push, state.queue)}}
  end

  def handle_call({:channel_link, channel, topic}, _from, state) do
    channels = state.channels

    channels =
      if Enum.any?(channels, fn {c, t} -> c == channel and t == topic end) do
        channels
      else
        [{channel, topic} | state.channels]
      end

    {:reply, channel, %{state | channels: channels}}
  end

  def handle_call({:channel_unlink, channel, topic}, _from, state) do
    channels = Enum.reject(state.channels, fn {c, t} -> c == channel and t == topic end)
    {:reply, channel, %{state | channels: channels}}
  end

  def handle_info({:connected, socket}, %{socket: socket} = state) do
    :erlang.send_after(state.heartbeat_interval, self(), :heartbeat)
    {:noreply, %{state | status: :connected}}
  end

  def handle_info(:heartbeat, %{status: :connected} = state) do
    ref = state.ref + 1
    send(state.socket, {:send, %{topic: "phoenix", event: "heartbeat", payload: %{}, ref: ref}})
    :erlang.send_after(state.heartbeat_interval, self(), :heartbeat)
    {:noreply, %{state | ref: ref}}
  end

  def handle_info(:heartbeat, state) do
    {:noreply, state}
  end

  # New Messages from the socket come in here
  def handle_info(
        {:receive, %{"topic" => topic, "event" => event, "payload" => payload, "ref" => ref}} =
          msg,
        %{channels: channels} = state
      ) do
    Enum.filter(channels, fn {_channel, channel_topic} ->
      topic == channel_topic
    end)
    |> Enum.each(fn {channel, _} ->
      send(channel, {:trigger, event, payload, ref})
    end)

    {:noreply, state}
  end

  def handle_info({:closed, reason, socket}, %{socket: socket} = state) do
    Enum.each(state.channels, fn {pid, _channel} ->
      send(pid, {:trigger, "phx_error", :closed, nil})
    end)

    if state.reconnect == true do
      :erlang.send_after(state[:reconnect_interval], self(), :connect)
    end

    state.sender.handle_close(reason, %{state | status: :disconnected})
  end

  def handle_info(:flush, %{status: :connected} = state) do
    state =
      case :queue.out(state.queue) do
        {:empty, _queue} ->
          state

        {{:value, push}, queue} ->
          send(state.socket, {:send, push})
          :erlang.send_after(100, self(), :flush)
          %{state | queue: queue}
      end

    {:noreply, state}
  end

  def handle_info(:flush, state) do
    :erlang.send_after(100, self(), :flush)
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    url =
      URI.parse(state.url)
      |> Map.put(:query, URI.encode_query(state.params))
      |> to_string

    {:ok, pid} = state[:adapter].open(url, state[:adapter_opts])
    {:noreply, %{state | socket: pid}}
  end

  def terminate(reason, _state) do
    :ok
  end
end
