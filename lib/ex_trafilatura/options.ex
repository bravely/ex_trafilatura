defmodule ExTrafilatura.Options do
  @moduledoc false
  # Validates a caller's keyword list and splits it in two: the size cap
  # `ExTrafilatura.extract/2` enforces, and the struct the NIF decodes. Callers
  # go through `ExTrafilatura.extract/2`; nothing here is public API.
  #
  # **An unknown key is refused, not ignored**, and so is an invalid value. Both
  # raise, because exceptions here mean exactly one thing: you called it wrong.
  # Nothing that arrives from the network at runtime can reach this module. The
  # price a caller pays is `Keyword.take/2` before passing a superset of their
  # own config; the reasoning behind charging it is on #11.
  #
  # A key the caller did not name comes out as `nil`, which the Rust side reads
  # as "leave the crate's own default alone". That is what makes `extract/1` the
  # crate's default call rather than a reconstruction of it; the proof is
  # `no_overrides_is_the_crates_default_call` in `native/`.

  # The shape that crosses the boundary, and the only place the twelve *crate*
  # keys are written down. It is declared rather than assembled: `%__MODULE__{}`
  # compiles to a literal map carrying all twelve, which matters because
  # `Overrides` on the Rust side is a `#[derive(NifStruct)]` naming this module,
  # and its generated decoder reads every field — a key that is merely absent is
  # a decode failure there, not a `None`. Being a struct puts that out of reach.
  #
  # The thirteenth key, `max_input_bytes`, is deliberately not here: it is ours
  # rather than the crate's, it is consumed in Elixir before the NIF is reached,
  # and adding it to this struct would make the Rust decode fail. `normalize/1`
  # splits it back off, which is the one seam between the two kinds of key.
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

  # ADR-0001 §1: roughly 3x the heaviest realistic page, so it bounds memory and
  # catches the accident — a video file, a database dump, an unbounded
  # concatenation — without ever firing on legitimate work. A cap that fires on
  # real input is worse than no cap, because it teaches callers to raise it
  # blindly.
  @default_max_input_bytes 10 * 1024 * 1024

  # **No entry for a crate key may carry `default:`.** Those defaults are the
  # crate's, and they live in `Options::default()` on the Rust side; a key the
  # caller did not name has to arrive as `nil` so that nothing is assigned over
  # them. Declaring a default here would quietly turn `extract/1` from *the
  # crate's default call* into a reconstruction of it — and would not fail
  # loudly, because a default that happens to match the crate's is invisible.
  # Only a divergence would ever surface, by which point the two have drifted.
  # `normalize/1 leaves every field nil when given nothing` is the guard on it.
  #
  # `max_input_bytes` is the exception that proves it: there is no crate default
  # to preserve, because there is no such option downstream. Its default is ours
  # to choose and has to be declared somewhere, and here is the only place the
  # caller's value and ours are compared.
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
            html_date_override: [type: {:custom, __MODULE__, :iso_date, []}],
            max_input_bytes: [
              type: {:custom, __MODULE__, :size_cap, []},
              default: @default_max_input_bytes
            ]
          )

  # The size cap and the overrides `opts` names, or a
  # `NimbleOptions.ValidationError` naming the key that was wrong. A crate key
  # the caller did not name keeps the struct's `nil`; `max_input_bytes` is
  # always present, at the caller's value or ours.
  #
  # The tuple is the seam. One schema validates all thirteen keys, so a typo is
  # caught in one place, and exactly one of them is split back off here because
  # it is spent in Elixir and has nowhere to go on the Rust side. `struct!/2`
  # rather than `struct/2` so that a fourteenth key added to the schema and not
  # to the struct fails here rather than being dropped on the floor.
  #
  # `opts` is a keyword list by the time it arrives: `ExTrafilatura.extract/2`
  # guards on it, so the only thing that can raise from here is the schema.
  def normalize(opts) do
    {max_input_bytes, crate_keys} =
      opts
      |> NimbleOptions.validate!(@schema)
      |> Keyword.pop!(:max_input_bytes)

    {max_input_bytes, struct!(__MODULE__, crate_keys)}
  end

  # The three schema types that cannot be spelled declaratively. Public because
  # `{:custom, ...}` calls them by name, and each takes its own edge value —
  # `nil`, or `:infinity` — rather than sitting inside an `{:or, [...]}`, which
  # would flatten these messages into "didn't match any".

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

  @doc false
  # `:infinity` disables the cap outright, so that a wrong default is survivable
  # in place rather than requiring a release from us (ADR-0001 §2). Zero is
  # refused along with the negatives: a cap admitting only the empty document is
  # a mistake in every case rather than a way of spelling anything, and letting
  # it through would put the one input that cannot be too large on the wrong
  # side of the gate.
  def size_cap(:infinity), do: {:ok, :infinity}
  def size_cap(value) when is_integer(value) and value > 0, do: {:ok, value}

  def size_cap(value),
    do:
      {:error,
       "expected a byte count as a positive integer, or :infinity, got: #{inspect(value)}"}
end
