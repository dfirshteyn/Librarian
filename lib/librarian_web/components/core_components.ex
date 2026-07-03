defmodule LibrarianWeb.CoreComponents do
  use Phoenix.Component

  attr :flash, :map, default: %{}
  def flash_group(assigns) do
    ~H"""
    <div class="fixed top-4 right-4 z-50 space-y-2">
      <%= for {kind, msg} <- @flash do %>
        <div class={"rounded px-4 py-2 text-sm font-medium #{if kind == "error", do: "bg-red-100 text-red-800", else: "bg-green-100 text-green-800"}"}>
          <%= msg %>
        </div>
      <% end %>
    </div>
    """
  end
end
