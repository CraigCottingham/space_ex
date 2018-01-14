defmodule SpaceEx.Connection do
  use GenServer
  alias SpaceEx.Protobufs.{
    ConnectionRequest,
    ConnectionResponse,
    ProcedureCall,
    Argument,
    Request,
    Response,
  }

  @moduledoc """
  Establishes a connection to a kRPC server.

  This is the first step you'll need in any kRPC program.  Every other call in
  this library depends on having a connection.

  Connections allow pipelining.  Although the kRPC server will only handle one
  request at a time (and will always handle requests in order), multiple
  requests — issued by multiple Elixir processes sharing the same connection —
  can be "on the wire" at any given time.  This dramatically improves
  performance compared to the standard approach of sending a single request and
  waiting until it responds.

  However, be aware that if you issue a call that blocks for a long time, like
  `SpaceEx.SpaceCenter.AutoPilot.wait/2`, it will also block all other RPC
  calls on the same connection until it returns.

  For that reason, if you intend to use blocking calls, but you still want
  other code to continue issuing calls in the mean time, then you should
  consider establishing a separate connection for your blocking calls.
  """

  defmodule State do
    @moduledoc false

    @enforce_keys [:socket, :reply_queue]
    defstruct(
      socket: nil,
      reply_queue: nil,
      buffer: <<>>,
    )
  end

  @doc """
  Connects to a kRPC server.

  `opts` is a keyword list:

  * `opts[:host]` is the target hostname or IP (default: `127.0.0.1`)
  * `opts[:port]` is the target port (default: `50000`)
  * `opts[:name]` is the client name, displayed in the kRPC status window (default: autogenerated & unique)

  Returns a connection handle that can be used as the `conn` argument in RPC
  calls.  The connection is linked to the process that started it, so it will
  close when that process terminates.
  """

  def connect!(opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    pid
  end
    
  def init(opts) do
    host = opts[:host] || "127.0.0.1"
    port = opts[:port] || 50000
    name = opts[:name] || "SpaceEx-#{whoami()}"

    sock = Socket.TCP.connect!(host, port, packet: :raw)

    request =
      ConnectionRequest.new(type: :RPC, client_name: name)
      |> ConnectionRequest.encode

    send_message(sock, request)

    response =
      recv_message(sock)
      |> ConnectionResponse.decode

    case response.status do
      :OK -> sock
      _ -> raise "kRPC connection failed: #{inspect response.message}"
    end

    Socket.active(sock)
    {:ok, %State{
      socket: sock,
      reply_queue: :queue.new,
    }}
  end

  defp send_message(sock, message) do
    size =
      byte_size(message)
      |> :gpb.encode_varint

    Socket.Stream.send!(sock, size <> message)
  end

  # Only called during initialisation.
  # After that, the socket is in active mode,
  # and all replies come via handle_info messages.
  defp recv_message(sock, buffer \\ <<>>) do
    case Socket.Stream.recv!(sock, 1) do
      <<1 :: size(1), _ :: bitstring>> = byte ->
        # high bit set, varint incomplete
        recv_message(sock, buffer <> byte)

      <<0 :: size(1), _ :: bitstring>> = byte ->
        {size, ""} = :gpb.decode_varint(buffer <> byte)
        Socket.Stream.recv!(sock, size)

      nil -> raise "kRPC connection closed"
    end
  end

  @doc false
  def call_rpc(pid, service, procedure, args) do
    args =
      Enum.with_index(args)
      |> Enum.map(fn {arg, index} ->
        Argument.new(position: index, value: arg)
      end)

    call = ProcedureCall.new(
      service: service,
      procedure: procedure,
      arguments: args,
    )

    request =
      Request.new(calls: [call])
      |> Request.encode

    response =
      GenServer.call(pid, {:rpc, request}, :infinity)
      |> Response.decode

    if response.error do
      {:error, response.error}
    else
      [call_reply] = response.results

      if call_reply.error do
        {:error, call_reply.error}
      else
        {:ok, call_reply.value}
      end
    end
  end

  def handle_call({:rpc, bytes}, from, state) do
    send_message(state.socket, bytes)
    queue = :queue.in(from, state.reply_queue)

    {:noreply, %State{state | reply_queue: queue}}
  end

  def handle_info({:tcp, sock, bytes}, %State{socket: sock} = state) do
    buffer = state.buffer <> bytes
    {queue, buffer} = dispatch_replies(state.reply_queue, buffer)

    {:noreply, %State{state |
      reply_queue: queue,
      buffer: buffer,
    }}
  end

  defp dispatch_replies(queue, buffer) do
    case extract_reply(buffer) do
      {:ok, reply, new_buffer} ->
        new_queue = dispatch_reply(queue, reply)
        dispatch_replies(new_queue, new_buffer)

      {:error, :incomplete} -> {queue, buffer}
    end
  end

  defp dispatch_reply(queue, reply) do
    {{:value, from}, queue} = :queue.out(queue)
    GenServer.reply(from, reply)
    queue
  end

  defp extract_reply(buffer) do
    case safe_decode_varint(buffer) do
      {size, leftover} ->
        case leftover do
          <<reply :: bytes-size(size), buffer :: binary>> ->
            {:ok, reply, buffer}

          _ -> {:error, :incomplete}
        end

      nil -> {:error, :incomplete}
    end
  end

  defp safe_decode_varint(bytes) do
    if has_varint?(bytes) do
      :gpb.decode_varint(bytes)
    else
      nil
    end
  end

  defp has_varint?(<<>>), do: false
  defp has_varint?(<<0 :: size(1), _ :: bitstring>>), do: true # high bit unset, varint complete
  defp has_varint?(<<1 :: size(1), _ :: size(7), rest :: bitstring>>), do: has_varint?(rest) # high bit set, varint incomplete

  defp whoami do
    os_pid = System.get_pid
    [_, erlang_pid, _] = inspect(self()) |> String.split(~r/[<>]/)

    "#{os_pid}-#{erlang_pid}"
  end
end
