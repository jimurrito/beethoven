defmodule Beethoven.Listener do
  @moduledoc """
  TCP listener used to help Beethoven instances find each other.
  """

  use GenServer
  require Logger

  alias Beethoven.Core, as: CoreServer

  # Entry point for Supervisors
  def start_link(_args) do
    # Start GenServer that runs TCP
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  # Entry point for Non-linking starters
  def start(_args) do
    # Start GenServer that runs TCP
    GenServer.start(__MODULE__, [], name: __MODULE__)
  end

  # Callback for genserver start calls.
  @impl true
  def init(_args) do
    # Start Task manager for requests
    {:ok, task_pid} = Task.Supervisor.start_link(name: Beethoven.Listener.TaskSupervisor)
    # Create Monitor for the TaskSupervisor
    _ref = Process.monitor(task_pid)
    #
    # pull port from env file
    listener_port =
      Application.fetch_env(:beethoven, :listener_port)
      |> case do
        {:ok, value} ->
          value

        :error ->
          Logger.notice(":listener_port not set in config/*.exs. Using default value '33000'.")
          33000
      end

    #
    # Open Socket
    #
    port_string = Integer.to_string(listener_port)
    #
    socket =
      :gen_tcp.listen(
        listener_port,
        [:binary, active: false, reuseaddr: true]
      )
      |> case do
        # successfully opened socket
        {:ok, socket} ->
          Logger.debug("Now listening on port (#{port_string}).")
          #
          #
          # Start accepting requests
          GenServer.cast(__MODULE__, :accept)
          socket

        # Failed -> IP already in use
        {:error, :eaddrinuse} ->
          Logger.error(
            "Failed to bind listener socket to port [#{port_string}] as the port is already in-use. This is not an issue in ':clustered' mode."
          )

          #
          # Kill supervisor
          Process.whereis(Beethoven.Listener.TaskSupervisor)
          |> Process.exit("Beethoven.Listener -> :eaddrinuse | port: (#{port_string})")

          #
          throw(
            "Failed to bind listener socket to port [#{port_string}] as the port is already in-use. This is not an issue in ':clustered' mode."
          )

        # Failed -> Unmapped
        {:error, _error} ->
          Logger.error(
            "Unexpected error occurred while binding listener socket to port [#{port_string}]."
          )

          #
          # Kill supervisor
          Process.whereis(Beethoven.Listener.TaskSupervisor)
          |> Process.exit("Beethoven.Listener -> :unexpected | port: (#{port_string})")

          #
          throw(
            "Unexpected error occurred while binding listener socket to port [#{port_string}]."
          )
      end

    #
    # return to caller
    {:ok, socket}
  end

  #
  #
  #
  # Starts accepting requests.
  @impl true
  def handle_cast(:accept, socket) do
    Logger.debug("Listener Accepting new requests.")
    # FIFO accept the request from the socket buffer.
    {:ok, client_socket} = :gen_tcp.accept(socket)
    # Spawn working thread
    {:ok, pid} =
      Task.Supervisor.start_child(
        Beethoven.Listener.TaskSupervisor,
        fn -> serve(client_socket) end
      )

    # transfer ownership of the socket request to the worker PID
    :ok = :gen_tcp.controlling_process(client_socket, pid)

    # Recurse
    GenServer.cast(self(), :accept)

    # End cast
    {:noreply, socket}
  end

  #
  #
  #
  #
  #
  #
  #
  #
  # Fnc that runs in each request task.
  defp serve(client_socket) do
    #
    Logger.info("Beethoven received a coordination.")
    #
    # Read data in socket
    {:ok, payload} = :gen_tcp.recv(client_socket, 0)

    nodeName =
      payload
      # Remove \r\n from the payload (if present)
      |> String.replace("\r", "")
      |> String.replace("\n", "")
      # Convert to atom
      |> String.to_atom()

    Logger.debug("Node (#{nodeName}) has requested to join the Beethoven Cluster.")

    # test node asking to join
    case Node.ping(nodeName) do
      #
      #
      # Failed to connect to node
      :pang ->
        Logger.error("Failed to ping node (#{nodeName}).")
        :gen_tcp.send(client_socket, "pang_error")

      #
      #
      # Success -> connected to node
      :pong ->
        # add requester to Mnesia cluster
        :mnesia.change_config(:extra_db_nodes, [nodeName])
        |> case do
          #
          #
          # Joined successfully.
          {:ok, _} ->
            Logger.info("Node (#{nodeName}) joined the Beethoven Cluster.")
            # Ensure Coordinator is in ':clustered' mode now
            if GenServer.call(CoreServer, :get_mode) == :standalone do
              # Service is standalone
              GenServer.cast(CoreServer, :standalone_to_clustered)
            end

            # Send response to caller
            :gen_tcp.send(client_socket, "joined")

          #
          #
          # Failed to join - merge_schema_failed
          {:error, {:merge_schema_failed, msg}} ->
            Logger.error(
              "Node (#{nodeName}) failed to join Beethoven cluster 'merge_schema_failed': '#{msg}' "
            )

            # Send response to caller
            :gen_tcp.send(client_socket, "merge_schema_failed")

          #
          #
          # Failed - unexpected_error
          {:error, error} ->
            Logger.error(
              "Node (#{nodeName}) failed to join Beethoven cluster 'unexpected_error':"
            )

            IO.inspect({:unexpected_error, error})
            # Send response to caller
            :gen_tcp.send(client_socket, "unexpected_error")
        end
    end
  end

  #
  #
  #
  #
  #
  #
  # Only PID it would be monitoring is the supervisor
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, :shutdown}, socket) do
    Logger.critical(
      "Beethoven.Listener's task Supervisor has shutdown."
    )

    {:noreply, socket}
  end

  #
  #
  #
  #
  #
  #
  # Catch All handle_info
  # MUST BE AT BOTTOM OF MODULE FILE **WITHOUT THIS, COORDINATOR GENSERVER WILL CRASH ON UNMAPPED MSG!!**
  @impl true
  def handle_info(msg, state) do
    Logger.warning("Beethoven.Listener received an un-mapped message.")
    IO.inspect({:unmapped_msg, msg})
    {:noreply, state}
  end
end
