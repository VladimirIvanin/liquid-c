# frozen_string_literal: true

# Synthetic, self-contained workloads derived from Fleur's include patterns.
# No SVG artwork or platform implementation is copied from the theme. Expected
# HTML is constructed independently in Ruby, never by rendering Liquid.
module FleurIncludeWorkloads
  SOURCE = "https://github.com/liquid-hub/fleur/blob/f8edd032a5f74f02e359e6c7ad5b047c7bcc07e4/".freeze

  module_function

  def build
    [svg_filter_24, slider_include_state]
  end

  def svg_filter_24
    # Approximately 12 KB of static SVG across twelve independent conditions,
    # matching the shape (not the artwork) of Fleur's shared svg partial.
    icons = Array.new(12) do |index|
      name = "icon_#{index}"
      body = "<svg data-icon=\"#{name}\" viewBox=\"0 0 8 8\">" +
        ('<path d="M0 0h8v8H0z"/>' * 42) + "</svg>"
      [name, body]
    end.to_h
    rows = Array.new(12) do |index|
      { "id" => index + 1, "off" => "icon_#{index}", "on" => "icon_#{(index + 1) % 12}" }
    end
    partial = icons.map do |name, body|
      "{% if svg == '#{name}' %}#{body}{% endif %}"
    end.join
    source = "{% for row in rows %}<label data-id=\"{{ row.id }}\">" +
      "{% include 'svg' with row.off %}{% include 'svg' with row.on %}" +
      "</label>{% endfor %}<output>{{ svg }}</output>"
    alternate_rows = rows.reverse.map { |row| row.merge("off" => row.fetch("on"), "on" => row.fetch("off")) }
    {
      name: "svg_filter_24", source: source, partials: { "svg" => partial },
      assigns: { "rows" => rows, "svg" => "root-svg" }, expected: svg_expected(rows, icons, "root-svg"),
      alternate: {
        assigns: { "rows" => alternate_rows, "svg" => "alternate-svg" },
        expected: svg_expected(alternate_rows, icons, "alternate-svg"),
      },
      provenance: [SOURCE + "snippets/svg.liquid#L1", SOURCE + "snippets/filter_inputs.liquid#L16"],
    }
  end

  def slider_include_state
    products = Array.new(6) do |index|
      {
        "id" => index + 1, "label" => "item-#{index + 1}",
        "hidden" => index.zero? || index == 5,
        "variants" => Array.new(index % 3 + 1) { |variant| { "id" => "#{index + 1}.#{variant + 1}" } },
      }
    end
    source = "{% assign label = 'root-label' %}{% assign last_seen = 0 %}" +
      "{% assign seen_variants = 0 %}{% for product in products %}" +
      "{% assign seen_variants = 0 %}{% include 'slider' label: product.label %}" +
      "<i>{{ last_seen }}:{{ seen_variants }}:{{ label }}:{{ forloop.index }}</i>" +
      "{% endfor %}<footer>{{ last_seen }}:{{ seen_variants }}:{{ label }}</footer>"
    slider = "{% if forloop.first %}<section>{% endif %}" +
      "{% unless product.hidden %}<article data-label=\"{{ label }}\">" +
      "{% include 'card' %}<b>{{ forloop.index }}</b></article>{% endunless %}" +
      "{% assign last_seen = product.id %}{% if forloop.last %}</section>{% endif %}"
    card = "<strong>{{ label }}:{{ forloop.index }}</strong>" +
      "{% for variant in product.variants %}<span>{{ variant.id }}:{{ forloop.index }}:{{ label }}</span>" +
      "{% assign seen_variants = seen_variants | plus: 1 %}{% endfor %}" +
      "<em>{{ forloop.index }}</em>"
    alternate_products = products.reverse.each_with_index.map do |product, index|
      product.merge("hidden" => index == 1 || index == 3)
    end
    {
      name: "slider_include_state", source: source,
      partials: { "slider" => slider, "card" => card },
      assigns: { "products" => products, "label" => "input-label" }, expected: slider_expected(products),
      alternate: {
        assigns: { "products" => alternate_products, "label" => "alternate-input-label" },
        expected: slider_expected(alternate_products),
      },
      provenance: [SOURCE + "templates/product.liquid#L30", SOURCE + "snippets/products_slider.liquid#L25",
        SOURCE + "snippets/collection_filters.liquid#L59"],
    }
  end

  def svg_expected(rows, icons, root_svg)
    rows.map do |row|
      "<label data-id=\"#{row.fetch('id')}\">#{icons.fetch(row.fetch('off'))}" +
        "#{icons.fetch(row.fetch('on'))}</label>"
    end.join + "<output>#{root_svg}</output>"
  end

  def slider_expected(products)
    html = products.each_with_index.map do |product, index|
      html = index.zero? ? +"<section>" : +""
      seen = 0
      unless product.fetch("hidden")
        label = product.fetch("label")
        html << "<article data-label=\"#{label}\"><strong>#{label}:#{index + 1}</strong>"
        product.fetch("variants").each_with_index do |variant, variant_index|
          html << "<span>#{variant.fetch('id')}:#{variant_index + 1}:#{label}</span>"
          seen += 1
        end
        html << "<em>#{index + 1}</em><b>#{index + 1}</b></article>"
      end
      html << "</section>" if index == products.length - 1
      html << "<i>#{product.fetch('id')}:#{seen}:root-label:#{index + 1}</i>"
    end.join
    last = products.last
    seen = last.fetch("hidden") ? 0 : last.fetch("variants").length
    html + "<footer>#{last.fetch('id')}:#{seen}:root-label</footer>"
  end
end
