# LazyHTML is a dependency of an app's tests (Phoenix.LiveViewTest needs
# it), not of Masu: Masu.Test calls it, and it is not in the PLT.
[
  {"lib/masu/test.ex", :unknown_function}
]
