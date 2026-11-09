# frozen_string_literal: true

# Minimal synthetic templates derived from Fleur's execution patterns. These
# are not copies of the theme or implementations of application extensions.
# Expected HTML is built independently in Ruby, without rendering Liquid.
# All inputs are JSON primitives; callers may adapt them to Drops separately.
module FleurWorkloads
  SOURCE_ROOT = "https://github.com/liquid-hub/fleur/blob/f8edd032a5f74f02e359e6c7ad5b047c7bcc07e4".freeze

  module_function

  def build
    [cards(4), cards(12), comparison, array_pipeline]
  end

  def cards(variant_count)
    products = Array.new(12) do |index|
      variants = Array.new(variant_count) do |variant_index|
        price = 100 + index * 7 + (variant_index % 3) * 20
        # Include variants without a discount and repeated minimum prices.
        old_price = variant_index % 4 == 0 ? price : price + 25 + variant_index * 3
        { "price" => price, "old_price" => old_price }
      end
      {
        "id" => index + 1,
        "title" => "Product #{index + 1}",
        "price_min" => variants.map { |variant| variant.fetch("price") }.min,
        "variants" => variants,
      }
    end

    source = [
      "{% assign card_prefix = 'outer' %}",
      "{% for product in products %}",
      "{% include 'fleur_card', card_prefix: 'grid' %}",
      # Assign writes the base scope; include arguments occupy a temporary scope.
      "<aside>{{ max_discount }}:{{ card_prefix }}</aside>",
      "{% endfor %}",
    ].join
    partials = {
      "fleur_card" => [
        "<article data-id=\"{{ product.id }}\" class=\"{{ card_prefix }}\">",
        "<h2>{{ product.title }}</h2>{% include 'fleur_labels', label_prefix: 'sale' %}",
        "{% assign old_price_min = 0 %}{% for variant in product.variants %}",
        "{% if variant.price == product.price_min and variant.old_price > variant.price %}",
        "{% if old_price_min == 0 or variant.old_price < old_price_min %}",
        "{% assign old_price_min = variant.old_price %}{% endif %}{% endif %}{% endfor %}",
        "<strong>{{ product.price_min }}</strong><del>{{ old_price_min }}</del>",
        "<small>{{ max_discount }}</small></article>",
      ].join,
      "fleur_labels" => [
        "{% assign max_discount = 0 %}{% for variant in product.variants %}",
        "{% if variant.old_price > variant.price %}",
        # Multiply before integer division so integer-only data has meaningful
        # discounts. This is a derived workload, not Fleur's exact formula.
        "{% assign discount = variant.price | times: 100 | divided_by: variant.old_price | times: -1 | plus: 100 | round: 0 %}",
        "{% if discount > max_discount %}{% assign max_discount = discount %}{% endif %}",
        "{% endif %}{% endfor %}<b class=\"{{ label_prefix }}\">{{ max_discount }}%</b>",
      ].join,
    }
    result = fixture(variant_count == 4 ? "cards_variants_12" : "cards_variants_12x12", source,
      { "products" => products }, cards_expected(products), partials,
      ["templates/collection.liquid#L74", "snippets/product-item.liquid#L25", "snippets/labels-list.liquid#L39"])
    alternate_products = products.map do |product|
      variants = product.fetch("variants").map do |variant|
        { "price" => variant.fetch("price") + 13, "old_price" => variant.fetch("old_price") + 29 }
      end
      product.merge("title" => "Updated #{product.fetch('title')}", "variants" => variants,
        "price_min" => variants.map { |variant| variant.fetch("price") }.min)
    end
    result[:alternate] = { assigns: { "products" => alternate_products }, expected: cards_expected(alternate_products) }
    result
  end

  def cards_expected(products)
    products.map do |product|
      discounted = product.fetch("variants").select { |v| v.fetch("old_price") > v.fetch("price") }
      max_discount = discounted.map { |v| 100 - v.fetch("price") * 100 / v.fetch("old_price") }.max || 0
      old_price_min = discounted.select { |v| v.fetch("price") == product.fetch("price_min") }
        .map { |v| v.fetch("old_price") }.min || 0
      "<article data-id=\"#{product.fetch('id')}\" class=\"grid\"><h2>#{product.fetch('title')}</h2>" \
        "<b class=\"sale\">#{max_discount}%</b><strong>#{product.fetch('price_min')}</strong>" \
        "<del>#{old_price_min}</del><small>#{max_discount}</small></article>" \
        "<aside>#{max_discount}:outer</aside>"
    end.join

  end

  def comparison
    properties = Array.new(12) { |index| { "handle" => "p#{index}", "title" => "Property #{index}" } }
    products = Array.new(8) do |product_index|
      values = {}
      properties.each_with_index do |property, property_index|
        # Missing properties exercise the ordinary non-strict nil path.
        next if (product_index + property_index) % 7 == 0

        values[property.fetch("handle")] = {
          "characteristics" => Array.new(1 + (product_index + property_index) % 3) do |index|
            { "title" => "C#{product_index}.#{property_index}.#{index}" }
          end,
        }
      end
      { "id" => product_index + 1, "properties" => values }
    end
    source = [
      "<table>{% for property in properties %}<tr><th>{{ property.title }}</th>",
      "{% for product in products %}<td data-id=\"{{ product.id }}\">",
      "{% for characteristic in product.properties[property.handle].characteristics %}",
      "{{ characteristic.title }}{% unless forloop.last %},{% endunless %}{% endfor %}",
      "</td>{% endfor %}</tr>{% endfor %}</table>",
    ].join
    result = fixture("comparison_8x12", source, { "products" => products, "properties" => properties },
      comparison_expected(products, properties), {}, ["snippets/compares_body.liquid#L48"])
    alternate_properties = properties.reverse.map { |property| property.merge("title" => "Updated #{property.fetch('title')}") }
    alternate_products = products.reverse.map do |product|
      values = product.fetch("properties").transform_values do |value|
        { "characteristics" => value.fetch("characteristics").reverse.map do |characteristic|
          { "title" => "Updated #{characteristic.fetch('title')}" }
        end }
      end
      product.merge("properties" => values)
    end
    result[:alternate] = {
      assigns: { "products" => alternate_products, "properties" => alternate_properties },
      expected: comparison_expected(alternate_products, alternate_properties),
    }
    result
  end

  def comparison_expected(products, properties)
    "<table>" + properties.map do |property|
      cells = products.map do |product|
        values = product.fetch("properties")[property.fetch("handle")]
        titles = values ? values.fetch("characteristics").map { |value| value.fetch("title") }.join(",") : ""
        "<td data-id=\"#{product.fetch('id')}\">#{titles}</td>"
      end.join
      "<tr><th>#{property.fetch('title')}</th>#{cells}</tr>"
    end.join + "</table>"
  end

  def array_pipeline
    items = Array.new(8) do |item_index|
      {
        "product" => {
          "related_products" => Array.new(6) do |index|
            id = (item_index * 5 + index * 3) % 19
            { "id" => id, "title" => "Related #{id}" }
          end,
        },
      }
    end
    source = [
      "{% assign cart_products = cart.items | map: 'product' %}",
      "{% assign related_products = cart_products | map: 'related_products' | sort: 'id' %}",
      "<p>{{ related_products | map: 'title' | join: ', ' }}</p>",
    ].join
    result = fixture("array_pipeline_8x6", source, { "cart" => { "items" => items } }, array_expected(items),
      {}, ["snippets/cart_similar.liquid#L1", "snippets/option_active.liquid#L10"])
    alternate_items = items.reverse.map do |item|
      { "product" => { "related_products" => item.fetch("product").fetch("related_products").map do |product|
        product.merge("title" => "Updated #{product.fetch('title')}")
      end } }
    end
    result[:alternate] = { assigns: { "cart" => { "items" => alternate_items } }, expected: array_expected(alternate_items) }
    result
  end

  def array_expected(items)
    "<p>" + items.flat_map { |item| item.fetch("product").fetch("related_products") }
      .sort_by { |product| product.fetch("id") }.map { |product| product.fetch("title") }.join(", ") + "</p>"
  end

  def fixture(name, source, assigns, expected, partials, paths)
    {
      name: name, source: source, partials: partials, assigns: assigns,
      expected: expected, provenance: paths.map { |path| "#{SOURCE_ROOT}/#{path}" },
    }
  end
end
