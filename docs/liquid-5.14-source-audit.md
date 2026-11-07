# Источники сценариев Liquid 5.14.0

Проверено 8 ноября 2026 года. Эталон: Shopify/liquid, тег `v5.14.0`,
commit `4e39ae4cc3da73921923c0669e0fc84a66b2f696`.
Основа расширения: `a67ddfc174247f4e199c25471f79b2fdf3770e3c`.

В [инвентаризации](liquid-c-source-inventory.json) перечислены все 227 записей
issues и PR из трёх страниц GitHub API, включая 31 issue. Ниже указаны результаты
разбора источников, относящихся к поведению движка и тестовой инфраструктуре.
Число записей не равно числу ошибок. Экспериментальные оптимизации, packaging и
запросы новых возможностей не считаются подтверждёнными регрессиями.

## Debian

Источник: [серия ruby-liquid-c 4.2.0-6](https://sources.debian.org/patches/ruby-liquid-c/4.2.0-6/).

| Патч | Что проверяем | Результат для этой ветки |
| --- | --- | --- |
| `0001 Drop git from gemspec` | Упаковка без `.git` | Не относится к семантике Liquid; gemspec не менялся |
| `0002 Disable Wincompatible pointer types` | Сборка GCC, типы native-указателей | Предупреждения не подавляются; см. также upstream PR #226; 32-bit остаётся непроверенным |
| `0003 Move auto_compact assignment` | GC на платформах без compaction | Отдельные safety-процессы; локально проверена x86_64 Linux, ppc64el недоступен |
| `0004 hash format inspect` | Изменение `Hash#inspect` в Ruby 3.4 | Новый `test_hash_output_keeps_liquid_format`; старые ожидания исходных тестов остаются видимыми |
| `0005 parse expression arguments` | Новые аргументы `parse_expression`, ошибочный UTF-8 | `test_safe_expression_keyword`, `test_explicit_unsafe_expression_flag`, `test_invalid_utf8_source`; простого принятия `**kwargs` недостаточно для контракта `strict2` |
| `minitest 6 compat` | Mock helpers и assertions | Для воспроизводимости выбран Minitest 5.22.3, helper подключает `minitest/mock`; поддержка Minitest 6 не заявляется |

## Открытые и закрытые issues liquid-c

Все номера ниже относятся к [Shopify/liquid-c](https://github.com/Shopify/liquid-c/issues).
Их URL также есть в JSON-инвентаризации.

| Issues | Покрытие или граница проверки |
| --- | --- |
| #197: приватный `Tokenizer#shift` | Новый `test_tokenizer_shift_is_public`; также исходные tokenizer-тесты и custom block/tag |
| #188: не найден upstream `test_helper` | Helper загружается абсолютным путём из закреплённого gem; полный набор из 67 файлов запускается отдельно от собственных тестов |
| #177: вывод Array | `test_nested_array`, исходный `VariableTest#test_write_array`, upstream variable/hash rendering; эталон сохраняет рекурсивную конкатенацию |
| #176: Marshal ResourceLimits | `api_marshal` в сравнительном наборе; известное ограничение native-объекта, отдельно от новых ошибок |
| #153: strict_filters | `test_strict_filters`, upstream filter-тесты |
| #109: exception renderer падает | `test_exception_renderer_raises_without_corrupting_vm`, исходный `BlockTest#test_exception_renderer_exception` |
| #84: перемещение констант GC | `test_gc_compaction_keeps_compiled_values_alive`, `test_gc_stress_parse_render`, исходный GCStressTest |
| #65: бинарный буфер | `test_binary_output_with_unicode`, `api_binary_buffer`; фиксируется известное ограничение C относительно чистого Liquid |
| #9: чтение за концом whitespace | `test_whitespace_only_expression_does_not_overread`; пустой, короткий и длинный whitespace |
| #7: keyword args без пробелов | `test_filter_options_are_fresh_and_mutable`, исходные filter keyword tests |
| #80: profiler | `test_profile_produces_ruby_tree`, `api_profile`, все upstream profiler tests; используется предусмотренный Ruby fallback |
| #77: сериализация, #78: компиляция вложенных тел, #83: native if/unless | Запросы возможностей; native compiler не добавляется. Поведение проверяется через существующие Ruby/C-пути |
| #196, #185, #175, #164, #163, #125, #32, #20 | Вопросы установки, Ruby, ОС и компилятора: проверка доступных Ruby 3.2/3.3/3.4; macOS, Ruby 2.7 и 32-bit вне локального прогона |
| #223, #218, #171, #47, #36, #35, #29, #19, #5 | Релизы, использование, metadata и benchmarks; самостоятельных регрессий шаблонного языка не устанавливают |

## Патчи и PR liquid-c

| Источники | Сценарии |
| --- | --- |
| [#229](https://github.com/Shopify/liquid-c/pull/229), #174, #139 | if/unless/case, повторные `when`, for/tablerow, break/continue, родительский цикл, counters, custom tags/blocks, ошибки и GC. Взяты сценарии; код экспериментального парсера и его ожидаемые результаты не переносились |
| [#227](https://github.com/Shopify/liquid-c/pull/227) | Кеш выражений при отключённых native nodes: `test_expression_cache_is_populated`, `test_lru_expression_cache`, `test_expression_cache_disabled`, `api_cache*` |
| #226, #214, #211, #187, #186, #167, #124, #73, #37, #31, #21, #14, #4, #2 | Типы VALUE, указатели, предупреждения, ABI: сборка существующего C-кода, GC и исходные unit-тесты; подавление warnings не добавлено |
| #220, #219, #210, #151, #121, #120, #74, #67, #66, #18 | Невалидный UTF-8, Unicode diagnostics, String subclass, encoding output: новый invalid UTF-8 набор, NUL diagnostics, corpus `encoding_*`, исходные tokenizer/variable tests |
| #216, #215, #212, #152 | Порядок `context=`/`to_liquid`, Drops как ключи и индексы: `test_drop_receives_context_before_to_liquid`, `test_drop_as_*`, `api_context_drop`, `api_drop_*` |
| #209, #200, #199, #207, #148, #135, #134, #117, #71, #57, #52, #43, #42, #39, #30, #27 | Tokenizer, raw, liquid, custom tags, trim: исходные raw/tokenizer tests; corpus `raw_*`, `quoted_*`, `trim_*`; safety inline comment; новый явный whitespace compatibility test |
| #192, #191, #190, #183, #182, #161, #160, #159, #158, #157, #154, #149, #147, #145, #142, #116, #109, #94, #93, #90, #88, #68, #56, #55 | Очистка стека, GC, ошибки компиляции, keyword hash, fallback: safety tests, повторное выполнение после ошибок, mutable filter options, source-size boundary; исходные block/expression tests |
| #179, #178, #150, #143, #126, #123, #122, #115, #107, #106, #104, #103, #98, #92, #85, #81, #76, #64, #61, #60, #50, #48, #38, #34, #28, #24, #23, #17, #15, #13, #12, #11 | Литералы, числа, диапазоны, lookup, strict parser, лимиты, ошибки и номера строк: все upstream tests плюс новые regression и сравнительные сценарии |

Остальные записи инвентаризации относятся к зависимостям, CI, документации,
benchmark-инструментам или внутреннему устройству инструкций. Они не превращались
в искусственные failing assertions по структуре реализации.

## Liquid 5

Изучены [History.md тега 5.14.0](https://github.com/Shopify/liquid/blob/v5.14.0/History.md),
исходники и полный `test/{unit,integration}` этого тега.
Особое внимание: Environment с 5.6, safe parsing, `strict2` и `self`, новые array
filters, to_s/BigDecimal, накопительные лимиты, RangeSlice и учёт диапазонов 5.14.

Дополнительные обсуждения:

- [#1699](https://github.com/Shopify/liquid/issues/1699): inline comments — safety test и upstream inline_comment tests.
- [#1566](https://github.com/Shopify/liquid/issues/1566): blank/empty — отдельные регрессии и corpus. Предлагаемое в issue поведение не подменяет фактический 5.14.0.
- [#1806](https://github.com/Shopify/liquid/issues/1806): несколько совпадающих `when` — `test_case_fallthrough` ожидает `ab`.
- [#1205](https://github.com/Shopify/liquid/issues/1205): передача контекста Drops — новые fixtures и upstream drop/self_drop tests.

## InSales

Источник: `/home/ivaninvladimir/work/insales_workspace/insales`, ветка
`liquid5-fix-tests`, SHA `d435a50ec9297a8abbdf14df1fee429bddeb6c7a`.
Проверены migration commits `c361738f07d`, `4da07244d3a`, `d435a50ec92`,
документ `docs/liquid-4-to-5-breaking-changes.md`, initializer Liquid,
`spec/lib/liquid`, теги, фильтры, Drops и сценарии WABA.

| Прикладной источник | Самостоятельная проверка в liquid-c |
| --- | --- |
| template_compatibility_spec | limit/offset, offset continue, reversed, raw/comment, Unicode, Hash/Array/BigDecimal, literal dotted key, CRLF |
| template_include_compatibility_spec | In-memory FileSystem, вложенные snippets, повторный render, partial cache, присваивание во внешний context |
| template_filter_reload_spec | Повторная регистрация и кеш методов фильтров в Environment; без прикладного патча удаления старых модулей |
| template_whitespace_compatibility_spec | Чистый default 5.14.0 и явные `bug_compatible_whitespace_trimming: true/false` |
| cache_compatibility_spec, layout/content_for/yield, WABA | Минимальные custom tag/block и output buffer fixtures: отсутствие повторного вывода, обработка ошибок, вызов тега один раз |
| BuyerLocationContextDrop и другие Drops | Назначение context до to_liquid, ленивая Proc, вложенные lookup и повторный render |

Hook `Variable#render`, используемый inline-редактором, проверен минимальным
счётчиком вызовов в отдельном safety-процессе. Один и тот же hook подключается
в pure и C; обход hook native VM зафиксирован как ограничение L06.

Rails-патчи, база, Redis и прикладные фильтры не загружаются. Их особенности
(`nil == blank` под ActiveSupport, editable, Cache, legacy whitespace default)
не становятся требованиями к чистому Liquid. Полный RSpec InSales здесь не запускался.

## Проверки по границам C-представления

После gcov отдельно прочитаны непокрытые пути assembler/VM и ограничения
`vm_assembler.h`. Добавлены воспроизведения, которых нет в небольшом генераторе:

- 65 535, 65 536 и 65 537 различных constants: найдено оборачивание `uint16_t`
  индекса и неверный вывод, R14 в отчёте.
- 254, 255 и 256 positional filter arguments: native-предел 254, L04.
- 255 и 256 keyword keys: native-предел 255, L05.

Каждый сценарий выполняется отдельно с таймаутом. Проверка целого вывода большого
шаблона использует SHA-256, чтобы failing assertion не печатал мегабайтный diff.
