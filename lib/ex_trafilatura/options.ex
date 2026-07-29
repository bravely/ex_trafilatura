defmodule ExTrafilatura.Options do
  @moduledoc false
  # Turns a caller's keyword list into the struct the NIF decodes. Callers go
  # through `ExTrafilatura.extract/2`; nothing here is public API.
  #
  # **An unknown key is refused, not ignored.** This reverses #11 §7, which
  # decided the opposite and accepted the cost in writing: a typo'd
  # `exclude_comment:` was "undiscoverable except by noticing the wrong output".
  # That cost was about to grow — #31 adds `max_input_bytes`, where a typo
  # silently reinstates a 10 MB cap — and the reversal was free while nothing
  # had shipped. The price is that a caller passing a superset of their own
  # config must `Keyword.take/2` first. Recorded on #11.
  #
  # Both refusals raise, because exceptions here mean exactly one thing: you
  # called it wrong. Nothing that arrives from the network at runtime can reach
  # this module.
  #
  # A key the caller did not name comes out as `nil`, which the Rust side reads
  # as "leave the crate's own default alone". That is what makes `extract/1` the
  # crate's default call rather than a reconstruction of it; the proof is
  # `no_overrides_is_the_crates_default_call` in `native/`.

  # The shape that crosses the boundary, and the only place the twelve keys are
  # written down. It is declared rather than assembled: `%__MODULE__{}` compiles
  # to a literal map carrying all twelve, which matters because `Overrides` on
  # the Rust side is a `#[derive(NifStruct)]` naming this module, and its
  # generated decoder reads every field — a key that is merely absent is a
  # decode failure there, not a `None`. Being a struct puts that out of reach.
  #
  # In the order `ExTrafilatura.extract/2` documents them.
  defstruct [
    :focus,
    :exclude_comments,
    :exclude_tables,
    :include_links,
    :include_images,
    :enable_fallback,
    :target_language,
    :has_essential_metadata,
    :original_url,
    :prune_selector,
    :excluded_authors,
    :html_date_override
  ]

  # **No entry here may carry `default:`.** The defaults are the crate's, and
  # they live in `Options::default()` on the Rust side; a key the caller did not
  # name has to arrive as `nil` so that nothing is assigned over them. Declaring
  # a default here would quietly turn `extract/1` from *the crate's default
  # call* into a reconstruction of it — and would not fail loudly, because a
  # default that happens to match the crate's is invisible. Only a divergence
  # would ever surface, by which point the two have drifted.
  # `normalize/1 leaves every field nil when given nothing` is the guard on it.
  @schema NimbleOptions.new!(
            focus: [type: {:in, [:balanced, :favor_precision, :favor_recall]}],
            exclude_comments: [type: :boolean],
            exclude_tables: [type: :boolean],
            include_links: [type: :boolean],
            include_images: [type: :boolean],
            enable_fallback: [type: :boolean],
            target_language: [type: {:or, [:string, nil]}],
            has_essential_metadata: [type: :boolean],
            original_url: [type: {:custom, __MODULE__, :absolute_url, []}],
            prune_selector: [type: {:or, [:string, nil]}],
            excluded_authors: [type: {:list, :string}],
            html_date_override: [type: {:custom, __MODULE__, :iso_date, []}]
          )

  @type t :: %__MODULE__{}

  # The overrides `opts` names, or a `NimbleOptions.ValidationError` naming the
  # key that was wrong. A key the caller did not name keeps the struct's `nil`.
  #
  # `opts` is a keyword list by the time it arrives: `ExTrafilatura.extract/2`
  # guards on it, so the only thing that can raise from here is the schema.
  @spec normalize(keyword()) :: t()
  def normalize(opts) do
    struct(__MODULE__, NimbleOptions.validate!(opts, @schema))
  end

  # The two schema types that cannot be spelled declaratively. Public because
  # `{:custom, ...}` calls them by name, and each takes `nil` itself rather than
  # sitting inside an `{:or, [..., nil]}`, which would flatten these messages
  # into "didn't match any".

  @doc false
  # The crate's `original_url` is a `url::Url`, whose one demand is a scheme: it
  # is the base that relative links in the document resolve against, and a
  # relative URL cannot be one. Nothing narrower is checked, because anything
  # the crate accepts we accept — `file:` and `mailto:` parse there, so they
  # pass here.
  def absolute_url(nil), do: {:ok, nil}

  def absolute_url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> {:ok, value}
      _ -> {:error, "expected an absolute URL with a scheme or nil, got: #{inspect(value)}"}
    end
  end

  def absolute_url(value),
    do: {:error, "expected an absolute URL with a scheme or nil, got: #{inspect(value)}"}

  @doc false
  # Sent on as a `{year, month, day}` triple rather than the struct: the crate's
  # own date is a `chrono::NaiveDate`, which is the ISO calendar and nothing
  # else, so the calendar is settled here rather than carried across and
  # ignored. A `%Date{}` in another calendar is refused rather than converted —
  # reading its fields verbatim would quietly produce a different day.
  def iso_date(nil), do: {:ok, nil}
  def iso_date(%Date{calendar: Calendar.ISO} = date), do: {:ok, {date.year, date.month, date.day}}

  def iso_date(value),
    do: {:error, "expected a Date in the ISO calendar or nil, got: #{inspect(value)}"}
end
