defmodule ExTrafilatura.Metadata do
  @moduledoc """
  The descriptive fields about a document rather than its body.

  Field names are the crate's own spellings — `sitename` is one word, and
  `page_type` is the raw `og:type` / JSON-LD `@type` — so that the crate's
  documentation reads directly onto this struct.

  **Absent is `nil` here**, unlike `ExTrafilatura.Result`, whose four streams are
  always binaries. Lists are `[]` when absent. The rule is stated per struct
  because the two are used differently: metadata fields serve
  `metadata.author || "Unknown"`, which `""` would break silently by being
  truthy.

  The crate cannot distinguish an empty field from an absent one —
  `<title></title>` and no `<title>` both produce `""` — so nothing is lost by
  reporting both as `nil`.

  ## The two fields that are not here

  The crate declares `id` and `fingerprint` and never assigns either, in any code
  path. They are permanently empty, so a caller checking them would conclude no
  page on the web has a fingerprint. They are omitted rather than shipped as
  fields that can only ever lie; restoring one later is additive.
  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          author: String.t() | nil,
          url: String.t() | nil,
          hostname: String.t() | nil,
          description: String.t() | nil,
          sitename: String.t() | nil,
          date: Date.t() | nil,
          categories: [String.t()],
          tags: [String.t()],
          license: String.t() | nil,
          language: String.t() | nil,
          image: String.t() | nil,
          page_type: String.t() | nil
        }

  defstruct [
    :title,
    :author,
    :url,
    :hostname,
    :description,
    :sitename,
    :date,
    :license,
    :language,
    :image,
    :page_type,
    categories: [],
    tags: []
  ]
end
