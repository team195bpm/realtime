defmodule EventTracker.Application do
  use Application

  def start(_type, _args) do
    children = [
      EventTracker.DBInit,
      {Phoenix.PubSub, name: EventTracker.PubSub},
      EventTracker.Endpoint
    ]

    opts = [strategy: :one_for_one, name: EventTracker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule EventTracker.DBInit do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    IO.puts("Initializing Database...")
    node = node()

    # Attempt to start. If it fails with the specific bad_type error, we NUKE the schema.
    try_create_db(node)
  end

  defp try_create_db(node) do
    # 1. Stop Mnesia to ensure we can modify schema
    :mnesia.stop()

    # 2. Create Schema (Disk)
    case :mnesia.create_schema([node]) do
      :ok -> IO.puts("Created new schema.")
      {:error, {_, {:already_exists, _}}} -> IO.puts("Schema found on disk.")
    end

    # 3. Start
    :mnesia.start()

    # 4. Create Table
    case :mnesia.create_table(:registrations, attributes: [:key, :count], disc_copies: [node]) do
      {:atomic, :ok} ->
        IO.puts("Table created successfully.")
        finish_startup()

      {:aborted, {:already_exists, _}} ->
        IO.puts("Table already exists.")
        finish_startup()

      {:aborted, {:bad_type, _, _, _}} ->
        IO.puts("!!! CORRUPT SCHEMA DETECTED !!!")
        IO.puts("The schema on disk is incompatible. Deleting and restarting...")

        # NUCLEAR OPTION: Delete the schema and retry ONCE
        :mnesia.stop()
        :mnesia.delete_schema([node])

        # Retry recursively (this will create a fresh schema now that the bad one is gone)
        try_create_db(node)

      other ->
        raise "Fatal Mnesia Error: #{inspect(other)}"
    end
  end

  defp finish_startup do
    :mnesia.wait_for_tables([:registrations], 15_000)
    IO.puts("Database Ready.")
    {:ok, nil}
  end
end

# --- The rest of the file is standard ---
defmodule EventTracker.DB do
  def get_all(event_id) do
    transaction = fn ->
      match_head = {:registrations, {event_id, :"$1"}, :"$2"}
      :mnesia.select(:registrations, [{match_head, [], [{{:"$1", :"$2"}}]}])
    end

    case :mnesia.transaction(transaction) do
      {:atomic, res} -> Enum.map(res, fn {c, n} -> %{category: c, count: n} end)
      _ -> []
    end
  end

  def increment(event_id, category_id) do
    key = {event_id, category_id}

    transaction = fn ->
      current =
        case :mnesia.read(:registrations, key) do
          [{_, ^key, c}] -> c
          [] -> 0
        end

      :mnesia.write({:registrations, key, current + 1})
      current + 1
    end

    {:atomic, res} = :mnesia.transaction(transaction)
    res
  end

  def reset(event_id, category_id) do
    key = {event_id, category_id}

    transaction = fn ->
      :mnesia.write({:registrations, key, 0})
      0
    end

    {:atomic, 0} = :mnesia.transaction(transaction)
    0
  end

  def set(event_id, category_id, count) do
    key = {event_id, category_id}

    transaction = fn ->
      :mnesia.write({:registrations, key, count})
      count
    end

    {:atomic, val} = :mnesia.transaction(transaction)
    val
  end
end

defmodule EventTracker.EventChannel do
  use Phoenix.Channel

  def join("event:" <> event_id, _, socket) do
    send(self(), {:after_join, event_id})
    {:ok, socket}
  end

  def handle_info({:after_join, eid}, socket) do
    push(socket, "initial_state", %{data: EventTracker.DB.get_all(eid)})
    {:noreply, socket}
  end
end

defmodule EventTracker.UserSocket do
  use Phoenix.Socket
  channel("event:*", EventTracker.EventChannel)
  def connect(_, socket, _), do: {:ok, socket}
  def id(_), do: nil
end

defmodule EventTracker.ErrorJSON do
  def render(t, _), do: %{errors: %{detail: Phoenix.Controller.status_message_from_template(t)}}
end

defmodule EventTracker.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/api", EventTracker do
    pipe_through(:api)
    post("/register", RegistrationController, :create)
    post("/reset", RegistrationController, :reset)
    post("/set", RegistrationController, :set)
    get("/events/:event_id/counts", RegistrationController, :counts)
  end
end

defmodule EventTracker.RegistrationController do
  use Phoenix.Controller

  def create(conn, %{"event_id" => e, "category_id" => c}) do
    n = EventTracker.DB.increment(e, c)
    EventTracker.Endpoint.broadcast!("event:#{e}", "update", %{category: c, count: n})
    json(conn, %{status: "ok", count: n})
  end

  def reset(conn, %{"event_id" => e, "category_id" => c}) do
    EventTracker.DB.reset(e, c)
    EventTracker.Endpoint.broadcast!("event:#{e}", "update", %{category: c, count: 0})
    json(conn, %{status: "ok", count: 0})
  end

  def set(conn, %{"event_id" => e, "category_id" => c, "count" => count}) do
    EventTracker.DB.set(e, c, count)
    EventTracker.Endpoint.broadcast!("event:#{e}", "update", %{category: c, count: count})
    json(conn, %{status: "ok", count: count})
  end

  def counts(conn, %{"event_id" => e}) do
    data = EventTracker.DB.get_all(e)
    json(conn, %{status: "ok", counts: data})
  end
end

defmodule EventTracker.Endpoint do
  use Phoenix.Endpoint, otp_app: :event_tracker
  socket("/socket", EventTracker.UserSocket, websocket: [path: "/websocket"], longpoll: false)

  def config_change(c, _n, r) do
    EventTracker.Endpoint.config_change(c, r)
    :ok
  end

  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(EventTracker.Router)
end
