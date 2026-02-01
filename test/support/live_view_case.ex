defmodule BatcherWeb.LiveViewCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a LiveView connection.

  Such tests rely on `Phoenix.LiveViewTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint BatcherWeb.Endpoint

      use BatcherWeb, :verified_routes

      # Import conveniences for testing with connections
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import BatcherWeb.ConnCase
      import BatcherWeb.LiveViewCase
    end
  end

  setup tags do
    Batcher.DataCase.setup_sandbox(tags)

    # Switch to shared mode so GenServer processes (like BatchBuilder) can access the sandbox
    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Batcher.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
