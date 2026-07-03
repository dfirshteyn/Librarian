defmodule LibrarianWeb.ErrorHTML do
  use LibrarianWeb, :html
  def render(template, _), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule LibrarianWeb.ErrorJSON do
  def render(template, _), do: %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
end
