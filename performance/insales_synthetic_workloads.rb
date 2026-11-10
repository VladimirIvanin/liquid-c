# frozen_string_literal: true

# Synthetic workloads modeled after the supplied widget corpus.
# The runner
# supplies bench_money, bench_image_url, bench_marker, and bench_cache with the
# explicit deterministic contracts used below. Expected output is constructed
# independently in Ruby and must never be obtained by rendering Liquid.
#
# build returns JSON-compatible data. Consumers must copy assigns/partials when
# passing them to engines that mutate input. No scenario shares mutable input
# objects with another scenario.
module SyntheticWidgetWorkloads
  extend self

  def build
    cases = []
    [64, 384].each do |count|
      cases << fixture(
        "repeated_value_#{count}",
        Array.new(count, "{{ value }}").join("|"),
        { "value" => "Tea" },
        Array.new(count, "Tea").join("|"),
      )
    end

    count = 384
    unique_assigns = {}
    unique_source = Array.new(count) do |index|
      unique_assigns["value#{index}"] = "Tea"
      "{{ value#{index} }}"
    end.join("|")
    repeated_output = Array.new(count, "Tea").join("|")
    cases << fixture("unique_values_384", unique_source, unique_assigns, repeated_output)
    cases << fixture(
      "repeated_short_path_384",
      Array.new(count, "{{ product.title }}").join("|"),
      { "product" => { "title" => "Tea" } },
      repeated_output,
    )
    cases << fixture(
      "repeated_three_step_path_384",
      Array.new(count, "{{ product.details.brand.title }}").join("|"),
      { "product" => { "details" => { "brand" => { "title" => "Tea" } } } },
      repeated_output,
    )

    products = product_data
    cards_source = card_grid_source
    cards_expected = product_cards(products)
    cases << fixture(
      "card_grid_12",
      cards_source,
      { "products" => products },
      cards_expected,
      provenance: "system_widget_v4_short_card_product_1/snippet.liquid; system_widget_v4_product_9/snippet.liquid",
    )

    include_source = [
      "{% for product in products %}<article>{{ product.title }}",
      "{% include 'badge' %}</article>{% endfor %}",
    ].join
    badge_source = "{% if product.available %}<span>Available</span>{% else %}<span>Preorder</span>{% endif %}"
    include_expected = products.map do |product|
      badge = product.fetch("available") ? "Available" : "Preorder"
      "<article>#{product.fetch("title")}<span>#{badge}</span></article>"
    end.join
    cases << fixture(
      "include_badge_12",
      include_source,
      { "products" => products },
      include_expected,
      partials: { "badge" => badge_source },
      provenance: "system_widget_v4_product_9/snippet.liquid",
    )

    menus = Array.new(3) do |index|
      {
        "title" => "Menu #{index + 1}",
        "links" => Array.new(4) do |child|
          { "title" => "Link #{index + 1}.#{child + 1}", "url" => "/menu/#{index + 1}/#{child + 1}" }
        end,
      }
    end
    header_source = [
      "{% capture navigation %}{% for menu in menus %}",
      "{% assign links = menu.links %}<section><h2>{{ menu.title }}</h2><ul>",
      "{% for link in links %}{% if link.title != blank %}",
      "<li><a href=\"{{ link.url }}\">{{ link.title }}</a></li>",
      "{% endif %}{% endfor %}</ul></section>{% endfor %}{% endcapture %}",
      "<header>{{ navigation }}</header>",
    ].join
    header_expected = "<header>" + menus.map do |menu|
      links = menu.fetch("links").map do |link|
        "<li><a href=\"#{link.fetch("url")}\">#{link.fetch("title")}</a></li>"
      end.join
      "<section><h2>#{menu.fetch("title")}</h2><ul>#{links}</ul></section>"
    end.join + "</header>"
    cases << fixture(
      "captured_header_12_links",
      header_source,
      { "menus" => menus },
      header_expected,
      provenance: "system_widget_v4_header_12/snippet.liquid",
    )

    escaped_source = "{% for product in products %}<h2>{{ product.title | strip_html | escape }}</h2>{% endfor %}"
    cases << fixture(
      "strip_html_escape_12",
      escaped_source,
      { "products" => Array.new(12) { { "title" => "<b>Tea & mug</b>" } } },
      Array.new(12, "<h2>Tea &amp; mug</h2>").join,
      provenance: "system_widget_v4_footer_11/snippet.liquid",
    )

    cache_source = "{% bench_cache 'card-grid' %}#{cards_source}{% endbench_cache %}"
    ["miss", "hit"].each do |mode|
      cases << fixture(
        "fragment_cache_#{mode}",
        cache_source,
        { "products" => products },
        cards_expected,
        cache_mode: mode,
        provenance: "system_widget_v4_header_12/snippet.liquid",
      )
    end

    cases << fixture(
      "custom_marker_boundaries_64",
      Array.new(64, "{{ title }}{% bench_marker title %}{{ title }}").join("|"),
      { "title" => "Tea" },
      Array.new(64, "Tea<b>Tea</b>Tea").join("|"),
      provenance: "system_widget_v4_footer_11/snippet.liquid (custom tag boundary only)",
    )

    palette = [
      { "title" => "Red", "hex" => "#ff0000" },
      { "title" => "Green", "hex" => "#00ff00" },
      { "title" => "Blue", "hex" => "#0000ff" },
      { "title" => "White", "hex" => "#ffffff" },
    ]
    characteristics = [
      "RED",
      "White",
      "Unknown",
      "green",
      "BLUE",
      "Missing",
      "red",
      "WHITE",
      "Unlisted",
      "Green",
      "blue",
      "Absent",
    ].each_with_index.map do |title, index|
      { "id" => index + 1, "title" => title }
    end
    color_source = [
      "{% for characteristic in characteristics %}",
      "{% assign normalized_title = characteristic.title | downcase %}{% assign hex = '' %}",
      "{% for color in block_lists.with_template['filter_color'].filter-colors.blocks %}",
      "{% assign normalized_color = color.title | downcase %}",
      "{% if normalized_title == normalized_color %}{% assign hex = color.hex %}{% break %}{% endif %}",
      "{% endfor %}<i data-id=\"{{ characteristic.id }}\" style=\"color:{{ hex }}\">",
      "{{ characteristic.title }}</i>{% endfor %}",
    ].join
    # A lookup table gives an independent oracle for the nested Liquid search.
    palette_by_title = palette.to_h { |color| [color.fetch("title").downcase, color.fetch("hex")] }
    color_expected = characteristics.map do |characteristic|
      hex = palette_by_title.fetch(characteristic.fetch("title").downcase, "")
      "<i data-id=\"#{characteristic.fetch("id")}\" style=\"color:#{hex}\">#{characteristic.fetch("title")}</i>"
    end.join
    cases << fixture(
      "color_filter_search_12",
      color_source,
      {
        "characteristics" => characteristics,
        "block_lists" => { "with_template" => { "filter_color" => { "filter-colors" => { "blocks" => palette } } } },
      },
      color_expected,
      provenance: "https://github.com/liquid-hub/itb/blob/cb2364b8ba3b601f9c50944c99cd3aa003cc9cfc/project/components/collection_filters/filter_inputs.liquid#L42-L58",
    )
    cases
  end

  def fixture(id, source, assigns, expected, partials: {}, cache_mode: "off",
    provenance: "synthetic expression comparison")
    # The JSON round trip isolates every mutable container, including products
    # reused to construct logically identical cache-hit and cache-miss fixtures.
    require "json"
    JSON.parse(JSON.generate({
      "id" => id,
      "source" => source,
      "assigns" => assigns,
      "partials" => partials,
      "expected" => expected,
      "cache_mode" => cache_mode,
      "provenance" => provenance,
    }))
  end

  def product_data
    Array.new(12) do |index|
      {
        "id" => index + 1,
        "title" => "Product #{index + 1}",
        "price" => 1999 + index * 100,
        "image" => "product-#{index + 1}.jpg",
        "available" => index % 3 != 0,
      }
    end
  end

  def card_grid_source
    [
      "{% for product in products %}{% assign title = product.title %}",
      "{% capture price %}{{ product.price | bench_money }}{% endcapture %}",
      "<article data-id=\"{{ product.id }}\"><h2>{{ title }}</h2>",
      "<img src=\"{{ product.image | bench_image_url: 320, format: 'webp', quality: 80 }}\">",
      "<span>{{ price }}</span>{% if product.available %}<button>Buy</button>",
      "{% else %}<button>Preorder</button>{% endif %}</article>{% endfor %}",
    ].join
  end

  def product_cards(products)
    products.map do |product|
      cents = product.fetch("price")
      # Integer formatting is independent from the runner's float-based filter.
      price = "#{cents / 100}.#{(cents % 100).to_s.rjust(2, "0")}"
      button = product.fetch("available") ? "Buy" : "Preorder"
      "<article data-id=\"#{product.fetch("id")}\"><h2>#{product.fetch("title")}</h2>" \
        "<img src=\"/img/#{product.fetch("image")}?w=320&format=webp&quality=80\">" \
        "<span>#{price}</span><button>#{button}</button></article>"
    end.join
  end
end
