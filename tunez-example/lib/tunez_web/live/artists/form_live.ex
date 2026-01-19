defmodule TunezWeb.Artists.FormLive do
  use TunezWeb, :live_view

  # For edit artist
  def mount(%{"id" => artist_id}, _session, socket) do
    artist = Tunez.Music.get_artist_by_id!(artist_id)
    form = Tunez.Music.form_to_update_artist(artist)

    socket =
      socket
      |> assign(:form, to_form(form))
      |> assign(:page_title, "Edit Artist")

    {:ok, socket}
  end

  # For new artist
  def mount(_params, _session, socket) do
    form = Tunez.Music.form_to_create_artist()

    socket =
      socket
      |> assign(:form, to_form(form))
      |> assign(:page_title, "New Artist")

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app {assigns}>
      <.header>
        <.h1>{@page_title}</.h1>
      </.header>

      <.simple_form
        :let={form}
        id="artist_form"
        as={:form}
        for={@form}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={form[:name]} label="Name" />
        <.input field={form[:biography]} type="textarea" label="Biography" />
        <:actions>
          <.button type="primary">Save</.button>
        </:actions>
      </.simple_form>
    </Layouts.app>
    """
  end

  def handle_event("validate", %{"form" => form_data}, socket) do
    socket =
      update(socket, :form, fn form ->
        AshPhoenix.Form.validate(form, form_data)
      end)

    {:noreply, socket}
  end

  def handle_event("save", %{"form" => form_data}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, parms: form_data) do
      {:ok, artist} ->
        socket =
          socket
          |> put_flash(:info, "Artist created successfully")
          |> push_navigate(to: ~p"/artists/#{artist.id}")

        {:noreply, socket}

      {:error, form} ->
        socket =
          socket
          |> put_flash(:error, "Failed to create artist")
          |> assign(:form, to_form(form))

        {:noreply, socket}
    end
  end
end
