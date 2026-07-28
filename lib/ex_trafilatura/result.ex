defmodule ExTrafilatura.Result do
  @moduledoc """
  What a successful extraction returns: the four content streams, plus the
  document's metadata nested underneath.

  **Absent is `""` here**, never `nil`. `content_text` is the field every caller
  touches on every call, and it is empty only in the rare comments-only case — a
  nilable one would make `content_text <> comments_text` a landmine that most
  callers never trip and some ship. `ExTrafilatura.Metadata` takes the opposite
  rule, for the opposite reason.

  Metadata stays nested rather than flattened because that is the line the domain
  draws: metadata is *about* the document, main content *is* the document.
  Flattening would put `title` and `content_html` at the same level and dissolve
  the distinction.

  Neither struct derives `Jason.Encoder`; `Map.from_struct/1` is one call away
  and not worth a dependency in a 0.x.
  """

  alias ExTrafilatura.Metadata

  @type t :: %__MODULE__{
          content_text: String.t(),
          comments_text: String.t(),
          content_html: String.t(),
          comments_html: String.t(),
          metadata: Metadata.t()
        }

  defstruct content_text: "",
            comments_text: "",
            content_html: "",
            comments_html: "",
            metadata: %Metadata{}
end
