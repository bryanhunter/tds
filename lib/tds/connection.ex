defmodule Tds.Connection do
  use GenServer
  alias Tds.Protocol
  alias Tds.Messages

  import Tds.BinaryUtils
  import Tds.Utils

  @timeout :infinity

  ### PUBLIC API ###

  def start_link(opts) do
    opts = opts
      |> Keyword.put_new(:username, System.get_env("MSSQLUSER") || System.get_env("USER"))
      |> Keyword.put_new(:password, System.get_env("MSSQLPASSWORD"))
      |> Keyword.put_new(:hostname, System.get_env("MSSQLHOST") || "localhost")
      |> Enum.reject(fn {_k,v} -> is_nil(v) end)
    case GenServer.start_link(__MODULE__, []) do
      {:ok, pid} ->
        timeout = opts[:timeout] || @timeout
        case GenServer.call(pid, {:connect, opts}, timeout) do
          :ok -> {:ok, pid}
          err -> {:error, err}
        end
      err -> err
    end
  end

  def stop(pid, opts \\ []) do
    GenServer.call(pid, :stop, opts[:timeout] || @timeout)
  end

  def query(pid, statement, params, opts \\ []) do
    message = {:query, statement, params, opts}
    timeout = opts[:timeout] || @timeout
    call_proc(pid, message, timeout)
  end

  def proc(pid, proc, params, opts \\ []) do
    message = {:proc, proc, params, opts}
    timeout = opts[:timeout] || @timeout
    call_proc(pid, message, timeout)
  end

  defp call_proc(pid, message, timeout) do
    case GenServer.call(pid, message, timeout) do
      %Tds.Result{} = res -> {:ok, res}
      %Tds.Error{} = err  ->
        {:error, err}
    end
  end

  ### GEN_SERVER CALLBACKS ###

  def init([]) do
    {:ok, %{
      sock: nil, 
      opts: nil, 
      state: :ready, 
      tail: "", 
      queue: :queue.new, 
      bootstrap: false, 
      statement: nil, 
      pak_header: "", 
      pak_data: "",
      env: %{trans: <<0x00>>}}}
  end

  def handle_call(:stop, from, s) do
    GenServer.reply(from, :ok)
    {:stop, :normal, s}
  end

  def handle_call({:connect, opts}, from, %{queue: queue} = s) do
    host      = Keyword.fetch!(opts, :hostname)
    host      = if is_binary(host), do: String.to_char_list(host), else: host
    port      = opts[:port] || System.get_env("MSSQL_PORT") || 1433
    if is_binary(port), do: {port, _} = Integer.parse(port)
    timeout   = opts[:timeout] || @timeout
    sock_opts = [{:active, :once}, :binary, {:packet, :raw}, {:delay_send, false}]

    queue = :queue.in({{:connect, opts}, from}, queue)
    s = %{s | opts: opts, queue: queue}

    case :gen_tcp.connect(host, port, sock_opts, timeout) do
      {:ok, sock} ->
        s = put_in s.sock, {:gen_tcp, sock}
        Protocol.login(%{s | opts: opts, sock: {:gen_tcp, sock}})
      {:error, reason} ->
        error(%Tds.Error{message: "tcp connect: #{reason}"}, s)
    end
  end

  def handle_call(command, from, %{state: state, queue: queue} = s) do
    s = update_in s.queue, &:queue.in({command, from}, &1)
    if state == :ready do
      case next(s) do
        {:ok, s} -> {:noreply, s}
        {:error, error, s} -> error(error, s)
      end
    else
      {:noreply, s}
    end
  end

  def handle_info({:tcp, _, _data}, %{sock: {mod, sock}, opts: opts, state: :prelogin} = s) do
    case mod do
      :gen_tcp -> :inet.setopts(sock, active: :once)
      :ssl     -> :ssl.setopts(sock, active: :once)
    end
    Protocol.login(%{s | opts: opts, sock: {mod, sock}})
  end

  def handle_info({tag, _, data}, %{sock: {mod, sock}, tail: tail} = s)
      when tag in [:tcp, :ssl] do
    case new_data(tail <> data, %{s | tail: ""}) do
      {:ok, s} ->
        case mod do
          :gen_tcp -> :inet.setopts(sock, active: :once)
          :ssl     -> :ssl.setopts(sock, active: :once)
        end
        {:noreply, s}
      {:error, error, s} ->
        error(error, s)
    end
  end

  def handle_info({tag, _}, s) when tag in [:tcp_closed, :ssl_closed] do
    error(%Tds.Error{message: "tcp closed"}, s)
  end

  def handle_info({tag, _, reason}, s) when tag in [:tcp_error, :ssl_error] do
    error(%Tds.Error{message: "tcp error: #{reason}"}, s)
  end

  def new_query(statement, params, %{queue: queue} = s) do
    command = {:query, statement, params, []}
    {{:value, {_command, from}}, queue} = :queue.out(queue)
    queue = :queue.in_r({command, from}, queue)
    command(command, %{s | queue: queue})
  end

  def next(%{queue: queue} = s) do
    case :queue.out(queue) do
      {{:value, {command, _from}}, _queue} ->
        command(command, s)
      {:empty, _queue} ->
        {:ok, s}
    end
  end

  defp command({:query, statement, params, _opts}, s) do
    if params != [] do
      Protocol.send_param_query(statement, params, s)
    else
      Protocol.send_query(statement, s)
    end
  end

  defp command({:proc, proc, params, _opts}, s) do
    Protocol.send_proc(proc, params, s)
  end
  
  defp new_data(<<_data::0>>, s), do: {:ok, s}
  defp new_data(<<packet::binary>>, %{state: state, pak_data: buf_data, pak_header: buf_header, tail: tail} = s) do

    <<type::int8, status::int8, size::int16, head_rem::int32, data::binary>> = tail <> packet
    if buf_header == "" do

      buf_header = <<type::int8, status::int8, size::int16, head_rem::int32>>
    else
      data = tail <> packet
    end

    <<type::int8, status::int8, size::int16, _head_rem::int32>> = buf_header
    size = size - 8

    case data do
      <<data :: binary(size), tail :: binary>> ->
        case status do
          1 ->
            msg = Messages.parse(state, type, buf_header, buf_data<>data)
            case Protocol.message(state, msg, s) do
              {:ok, s} -> new_data(tail, %{s | pak_header: "", pak_data: "", tail: tail})
              {:error, _, _} = err -> err
            end
          _ ->
            {:ok, %{s | pak_data: buf_data <> data, pak_header: "", tail: tail}}
        end
      _ ->
        {:ok, %{s | tail: tail <> data, pak_header: buf_header}}
    end
  end

end
