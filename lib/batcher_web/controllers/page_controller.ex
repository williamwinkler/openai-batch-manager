defmodule BatcherWeb.PageController do
  use BatcherWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
