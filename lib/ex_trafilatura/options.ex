defmodule ExTrafilatura.Options do
  @moduledoc false
  # Turns a caller's keyword list into the twelve-key map the NIF decodes.
  # Callers go through `ExTrafilatura.extract/2`; nothing here is public API,
  # and deliberately so — a public `validate_options/1` was considered and
  # declined along with per-call `Logger` noise (#11 §7).
  #
  # Two rules, and they pull in opposite directions on purpose:
  #
  #   * An **unknown key is ignored**, so passing a superset from a caller's own
  #     config never crashes. The accepted cost is that a typo'd
  #     `exclude_comment:` is undiscoverable except by noticing the wrong output.
  #   * An **invalid value raises**, because exceptions here mean exactly one
  #     thing: you called it wrong. Nothing that arrives from the network at
  #     runtime can reach this module.
  #
  # A key the caller did not name is `nil` in the map and is *not applied* on
  # the Rust side, rather than being applied at a default of ours. That is what
  # makes `extract/1` the crate's default call rather than a reconstruction of
  # it; see `no_overrides_is_the_crates_default_call` in `native/`.

  # In the order `ExTrafilatura.extract/2` documents them, which is also the
  # order two wrong values are reported in.
  @keys [
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

  @unset Map.new(@keys, &{&1, nil})

  # The four whose crate field is an `Option`, and so the four for which `nil`
  # is a value the caller may pass rather than a wrong one. On the other eight
  # it is wrong, and saying so is the whole point of the second rule above —
  # `focus: nil` is a mistake, not a way of spelling `:balanced`.
  @nilable [:target_language, :original_url, :prune_selector, :html_date_override]

  @booleans [
    :exclude_comments,
    :exclude_tables,
    :include_links,
    :include_images,
    :enable_fallback,
    :has_essential_metadata
  ]

  @binaries [:target_language, :prune_selector]

  @focuses [:balanced, :favor_precision, :favor_recall]

  @doc """
  The twelve-key override map for `opts`, or an `ArgumentError` naming the first
  key whose value is wrong.
  """
  @spec normalize(keyword()) :: map()
  def normalize(opts) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError, "options must be a keyword list, got: #{inspect(opts)}"
    end

    # Reading the twelve known keys *out* of the list, rather than walking the
    # list and skipping what we do not recognise, is what makes ignoring an
    # unknown key structural: there is no branch that could stop doing it. It
    # also inherits `Keyword.fetch/2`'s first-wins rule on a repeated key.
    Enum.reduce(@keys, @unset, fn key, overrides ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(overrides, key, cast(key, value))
        :error -> overrides
      end
    end)
  end

  defp cast(key, nil) when key in @nilable, do: nil

  defp cast(:focus, value) when value in @focuses, do: value
  defp cast(:focus, value), do: invalid(:focus, value, "one of #{inspect(@focuses)}")

  defp cast(key, value) when key in @booleans and is_boolean(value), do: value
  defp cast(key, value) when key in @booleans, do: invalid(key, value, "a boolean")

  defp cast(key, value) when key in @binaries and is_binary(value), do: value
  defp cast(key, value) when key in @binaries, do: invalid(key, value, "a binary")

  defp cast(:original_url, value) when is_binary(value) do
    # The crate's `original_url` is a `url::Url`, whose one demand is a scheme:
    # it is the base that relative links in the document resolve against, and a
    # relative URL cannot be one. Nothing narrower is checked here, because
    # anything the crate accepts we accept — `file:` and `mailto:` parse there,
    # so they pass here.
    case URI.new(value) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> value
      _ -> invalid(:original_url, value, "an absolute URL, with a scheme")
    end
  end

  defp cast(:original_url, value), do: invalid(:original_url, value, "a binary")

  defp cast(:excluded_authors, value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      value
    else
      invalid(:excluded_authors, value, "a list of binaries")
    end
  end

  defp cast(:excluded_authors, value), do: invalid(:excluded_authors, value, "a list of binaries")

  # Sent as a `{year, month, day}` triple rather than the struct: the crate's
  # own date is a `chrono::NaiveDate`, which is the ISO calendar and nothing
  # else, so the calendar is settled here rather than carried across and
  # ignored. A `%Date{}` in another calendar is refused rather than converted —
  # reading its fields verbatim would quietly produce a different day.
  defp cast(:html_date_override, %Date{calendar: Calendar.ISO} = value),
    do: {value.year, value.month, value.day}

  defp cast(:html_date_override, value),
    do: invalid(:html_date_override, value, "a Date in the ISO calendar")

  defp invalid(key, value, expected) do
    raise ArgumentError,
          "invalid value for #{inspect(key)}: expected #{expected}, got: #{inspect(value)}"
  end
end
