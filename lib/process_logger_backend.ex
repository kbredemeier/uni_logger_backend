defmodule ProcessLoggerBackend do
  @moduledoc """
  A logger backend that forwards log messages to a process.

  ## Usage

  First add the logger to the backends:

  ```
  # config/config.exs

  config :logger, :backends, [{ProcessLoggerBackend, :console}]

  config :logger, level: :info
  ```

  Then configure the `pid` of the process that should receive the log messages
  by configuring the backend at runtime. This can be done for example from a
  `GenServer` that should receive the log messages:

  ```
  Logger.configure_backend({ProcessLoggerBackend, :console}, pid: self())

  receive do
    {level, msg, timestamp, meta} -> IO.puts "Received log"
    :flush -> IO.puts "Received flush"
  end
  ```

  The registered process will then receive messages when the logger is invoked.
  Therefore the registered process should implement `handle_info/2` for tuples
  like `{level, msg, timestamp, meta}` and for `:flush`. `:flush` is received
  when the logger is flushed by calling `Logger.flush/0`.
  """

  alias ProcessLoggerBackend.Config

  @behaviour :gen_event

  @typedoc "Type for timestamps"
  @type timestamp :: :calendar.datetime()

  @typedoc "Type for metadata"
  @type metadata :: Logger.metadata()

  @typedoc "Type for messages"
  @type msg :: any

  @typedoc "Type for log levels"
  @type level :: Logger.level()

  @typedoc "Options to configure the backend"
  @type opt ::
          {:level, level}
          | {:pid, GenServer.name()}
          | {:meta, metadata}
          | {:formatter, formatter}

  @typedoc "Collection type for `opt`"
  @type opts :: [opt]

  @typedoc """
  A formatter to format the log msg before sending. It can be either a
  function or a tuple with a module and a function name.

  The functions receives the log msg, a timestamp as a erlang time tuple and
  the metadata as arguments and should return the formatted log msg.
  """
  @type formatter :: {module, atom} | (level, msg, timestamp, metadata -> any)

  @typedoc """
  Serves as internal state of the `ProcessLoggerBackend` and as config.

  * `level` - Specifies the log level.
  * `pid` - Specifies the process pid or name that receives the log messages.
  * `meta` - Additional metadata that will be added to the metadata before
    formatting.
  * `name` - The name of the lggger. This cannot be overridden.
  * `formatter` - A optional function that is used to format the log messages
    before sending. See `formatter()`.
  """
  @type state :: %Config{
          level: level,
          pid: GenServer.name(),
          meta: metadata,
          name: atom,
          formatter: nil | formatter
        }

  @spec init({module, atom}) :: {:ok, state}
  def init({__MODULE__, name}) do
    {:ok, configure(name, [])}
  end

  def handle_call({:configure, opts}, %{name: name}) do
    {:ok, :ok, configure(name, opts)}
  end

  @spec configure(atom, opts) :: state
  defp configure(name, opts) do
    applied_opts =
      :logger
      |> Application.get_env(name, [])
      |> Keyword.merge(opts)
      |> Keyword.put(:name, name)

    Application.put_env(:logger, name, applied_opts)

    struct!(Config, applied_opts)
  end

  def handle_event(:flush, state) do
    if process_alive?(state.pid) do
      send(state.pid, :flush)
    end

    {:ok, state}
  end

  def handle_event({_level, group_leader, _info}, state)
      when node(group_leader) != node() do
    {:ok, state}
  end

  def handle_event(_, %{pid: nil} = state) do
    {:ok, state}
  end

  def handle_event({level, _, {Logger, msg, timestamp, meta}}, state) do
    with true <- should_log?(state, level),
         true <- process_alive?(state.pid),
         meta <- Keyword.merge(meta, state.meta),
         {:ok, msg} <- format(state.formatter, [level, msg, timestamp, meta]) do
      send(state.pid, {level, msg, timestamp, meta})
    end

    {:ok, state}
  end

  @spec should_log?(state, level) :: boolean
  defp should_log?(%{level: right}, left),
    do: :lt != Logger.compare_levels(left, right)

  @spec process_alive?(GenServer.name()) :: boolean
  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp format(nil, [_, msg, _, _]), do: {:ok, msg}
  defp format({mod, fun}, args), do: do_apply(mod, fun, args)
  defp format(fun, args), do: do_apply(fun, args)

  @spec do_apply(function, list) :: {:ok, any} | :error
  defp do_apply(fun, args) do
    {:ok, apply(fun, args)}
  rescue
    _ -> :error
  end

  @spec do_apply(module, atom, list) :: {:ok, any} | :error
  defp do_apply(mod, fun, args) do
    {:ok, apply(mod, fun, args)}
  rescue
    _ -> :error
  end
end
