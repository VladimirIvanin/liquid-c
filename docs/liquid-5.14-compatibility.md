# liquid-c и Liquid 5.14.0: первый этап, падающие тесты

Ветка `upgrade`, база `a67ddfc174247f4e199c25471f79b2fdf3770e3c`.
Проверка выполнена 8 ноября 2026 года на x86_64 Linux. Liquid закреплён на
`4e39ae4cc3da73921923c0669e0fc84a66b2f696`, точном commit тега `v5.14.0`.
Код `lib/`, `ext/` и публичный API расширения не менялись.

Чистый Liquid проходит исходный upstream-набор и новые регрессии на Ruby 3.2,
3.3 и 3.4. Для расширения зафиксированы 14 групп несовместимости и шесть ограничений.
Самая существенная находка — неверный вывод при переполнении таблицы constants,
без исключения и при размере шаблона меньше 1 МиБ.

Добавлены 102 самостоятельных теста, 184 сравнительных сценария, генератор из
256 шаблонов с seed `51400`, 12 safety-тестов и 4 проверки самого runner.
Подключены все 1062 upstream-теста из 67 файлов, отдельно от 85 исходных
unit-тестов liquid-c. Источники и связь с InSales описаны в
[каталоге источников](liquid-5.14-source-audit.md); полная инвентаризация GitHub —
[liquid-c-source-inventory.json](liquid-c-source-inventory.json).

## Запуск

Из корня проекта с выбранным Ruby:

```sh
bundle install
bundle exec rake compile
bundle exec rake test
```

`rake test` выполняет все группы, продолжает работу после падения отдельной группы
и в конце возвращает ненулевой статус. Для этого этапа красный итог ожидается:
рабочие исправления ещё не внесены. Нет новых `skip`, `pending`, ожидаемых падений
или подмен реализаций Liquid, исправляющих результат теста. Четыре skip при C/no_vm находятся в самом upstream:
он пропускает expression cache tests для liquid-c. Новый набор проверяет кеш
отдельно, без этих пропусков.

| Команда | Назначение |
| --- | --- |
| `bundle exec rake test:compatibility:upstream` | Все unit/integration-тесты оригинального Liquid |
| `bundle exec rake test:compatibility:regression` | Самостоятельные проверки Ruby API и рендеринга |
| `bundle exec rake test:compatibility:differential` | Сравнение 184 сценариев с отдельным чистым процессом |
| `bundle exec rake test:compatibility:generated` | 256 детерминированных шаблонов и данных |
| `bundle exec rake test:compatibility:safety` | Каждый safety-тест в отдельном процессе |
| `bundle exec rake test:compatibility:coverage` | Ruby line/branch coverage для legacy/upstream/regression |
| `bundle exec rake test:compatibility:c_coverage` | Отдельная C-сборка с `--coverage`, все группы, gcov JSON |
| `bundle exec rake test:compatibility:valgrind` | Изолированные safety-тесты через RubyMemcheck, с фильтрацией ошибок Ruby |

Valgrind должен быть установлен отдельно. В локальном окружении его нет;
результат memory checker здесь не заявляется. GC stress и compaction выполнены.

Выбор поднабора и воспроизведение:

```sh
ENGINES=pure,c MODES=strict bundle exec ruby -Ilib test/compatibility/run.rb regression
LIQUID_ENGINE=pure bundle exec ruby -Ilib test/compatibility/regression_test.rb --name test_safe_expression_keyword
LIQUID_ENGINE=c bundle exec ruby -Ilib test/compatibility/regression_test.rb --name test_safe_expression_keyword
CASE=expression_1_string MODES=strict bundle exec ruby -Ilib test/compatibility/compare.rb curated
CASE=seed_51400_10 MODES=strict bundle exec ruby -Ilib test/compatibility/compare.rb generated
CASE=gc_compaction ENGINES=c bundle exec ruby -Ilib test/compatibility/safety_runner.rb
```

`LIQUID_C_DISABLE_VM=true` сохранён как прежний способ выбрать `no_vm`, если
`LIQUID_ENGINE` не задан явно. `ENGINES` ограничивает матрицу Minitest и safety; сравнительный прогон всегда
использует pure и три конфигурации расширения. `MODES` ограничивает режимы.
Minitest seed по умолчанию `51400`, меняется через `TEST_SEED`. Генератор принимает
`GENERATOR_SEED` и `GENERATOR_COUNT`; идентификатор включает seed и индекс.
`CASE` сначала ищет точный ID сценария, затем — совпадение по фрагменту.
`TEST_TIMEOUT` задаёт лимит процесса, `RESULTS_DIR` — каталог результатов.
Пустые/неизвестные конфигурации завершаются ошибкой, а не зелёным пустым прогоном.

## Что именно сравнивается

| Конфигурация | Native nodes | Native evaluator |
| --- | --- | --- |
| `pure` | Нет | Нет; файл расширения не загружается |
| `c` | Да | Да |
| `no_vm` | Нет | Да |
| `disabled` | Нет | Нет; расширение загружено, `Liquid::C.enabled = false` |

Bootstrap проверяет фактический класс тела и `Context#evaluate`, записывает Ruby,
режим и путь загруженного `.so`. Это предотвращает зелёный прогон C-тестов через
случайный Ruby fallback. Исходники upstream и его `test_helper` берутся из
зафиксированного bundle; `$LOAD_PATH` не выбирает локальный helper по совпадению имени.

Bundler исполняет gemspec этого проекта, который определяет `Liquid::C::VERSION`
даже без расширения. В pure-процессе bootstrap удаляет только этот пустой namespace,
если в нём есть единственная константа VERSION. Иначе upstream ошибочно считает
C загруженным и вызывает отсутствующий `Liquid::C.enabled`. Методы Liquid в oracle
не переопределяются; отдельно проверяется отсутствие загруженного расширения.

Сравниваются байты и кодировка вывода, классы/сообщения исключений, номера строк,
предупреждения, `context.errors`, присваивания, счётчики custom tags, partial cache
и повторный render. Строки в JSON представлены Base64 и encoding, поэтому
повреждённый UTF-8 и NUL не теряются. Ошибки запуска, сигналы и таймауты фиксируются
отдельно от наблюдаемых исключений Liquid. Каждый процесс имеет отдельное окружение;
старое протекание `lax` в запуск без VM устранено.

## Подтверждённые причины несовместимости

Для каждого теста таблицы команда воспроизведения имеет вид:

```sh
LIQUID_ENGINE=c bundle exec ruby -Ilib test/compatibility/regression_test.rb --seed 51400 --name ИМЯ_ТЕСТА
```

Смена `c` на `pure` проверяет тот же контракт на оригинале. Для R14 используется
изолированный safety runner:

```sh
CASE=constant_table ENGINES=pure,c bundle exec ruby -Ilib test/compatibility/safety_runner.rb
```

Это группы причин,
а не сумма всех красных assertions: один дефект может ломать сотни тестов.

| ID | Источник → тест | Pure 5.14.0 → C | Предполагаемая причина |
| --- | --- | --- | --- |
| R01 | Debian 0005, Liquid Tag/Condition → `test_safe_expression_keyword` | `ok` → Ruby ArgumentError | `ParseContext#parse_expression(markup)` не принимает `safe:`; блокирует if/for/include/render и фильтры Ruby-пути |
| R02 | strict2 → `test_strict2_unsafe_expression_is_rejected`, `test_explicit_unsafe_expression_flag` | InternalError → принятие выражения либо ArgumentError | Переопределение не реализует запрет небезопасного разбора |
| R03 | Liquid 5.13 → `test_strict2_rejects_bare_brackets`, `test_rigid_alias_enforces_strict2` | SyntaxError → шаблон принимается | C strict parser не учитывает правила strict2/rigid |
| R04 | Liquid self/SelfDrop → `test_self_lookup_in_default_mode`, `test_strict2_self_lookup` | `ok` → пустой вывод | Native lookup не реализует неявный self |
| R05 | PR #227, upstream Expression → `test_expression_cache_is_populated`, `test_lru_expression_cache`, `test_expression_is_frozen` | Кеш/тот же frozen объект → новые незамороженные выражения и пустой кеш | Override обходит expression cache; проблема остаётся и при отключении C |
| R06 | Environment 5.6, custom tags InSales → `test_environment_tag_lookup`, `test_custom_tag_runs_once`, `test_custom_block_uses_existing_buffer_once` | Тег найден в переданном Environment → Unknown tag | C block parser запоминает registry при загрузке расширения, игнорирует переданный Environment и последующую смену Environment.default; `test_global_custom_block` также воспроизводит ошибку |
| R07 | InSales filter reload → `test_register_filter_after_strainer_was_created` | `new:x` → `x` | Мемоизированный `filter_methods_hash` не инвалидируется при регистрации фильтра |
| R08 | Liquid cumulative limits → `test_cumulative_render_limit`, `test_cumulative_assign_limit`, `test_cumulative_*_counter_survives_reset` | Лимит сохраняется через reset и превышение вызывает MemoryError → лимит игнорируется, методов счётчика нет | Native ResourceLimits поддерживает только старые поля |
| R09 | ResourceLimits contract → `test_fresh_limits_have_not_been_reached`, `test_reset_clears_reached_flag` | `reached? == false` → true | Native reset записывает reached_limit=true; давняя самостоятельная ошибка, не новая фича 5.14 |
| R10 | ResourceLimits contract → `test_unset_limits_are_nil`, `test_*_limit_can_be_disabled` | nil → LONG_MAX | Внутренний native sentinel просачивается в Ruby API |
| R11 | Числовые границы → `test_*_limit_accepts_large_integer` | Поддерживается `2**100` → RangeError | NUM2LONG ограничивает интерфейс машинным long; существующее различие реализаций |
| R12 | Utils.to_s, Ruby 3.4, InSales BigDecimal → `test_decimal_output`, `test_hash_output_keeps_liquid_format` | `12.3` и компактный Hash → экспоненциальный BigDecimal; Hash с пробелами на Ruby 3.4 | VM использует преобразование объекта, обходя актуальную нормализацию Liquid |
| R13 | Lexer diagnostics → `test_nul_is_preserved_in_syntax_error` | NUL присутствует в позиции неожиданного символа → символ исчезает | Формирование сообщения C lexer не сохраняет байт NUL |
| R14 | Анализ границы VM constants → `Liquid514SafetyTest#test_constant_table_does_not_wrap_at_65536` | 65 535/65 536/65 537 различных констант корректны → при 65 537 появляется чужое значение | `uint16_t` индекс в `vm_assembler_write_ruby_constant` оборачивается без проверки; размер шаблона меньше 1 МиБ, source-size fallback не срабатывает |

Отключение C — отдельная важная проверка: оно возвращает Ruby nodes/evaluator,
но не восстанавливает `ParseContext#parse_expression`. Поэтому `disabled` тоже
имеет несовместимости и не служит заменой чистому oracle.

### Ограничения native-реализации

| ID | Воспроизведение | Классификация |
| --- | --- | --- |
| L01 | `test_binary_output_with_unicode`, `api_binary_buffer`, issue #65 | Чистый Liquid принимает пустой ASCII-8BIT buffer и корректно выводит Unicode. C его отклоняет. Исходный unit-тест C специально ожидает такой отказ; это известное ограничение |
| L02 | `api_marshal`, issue #176 и #77 | Ruby ResourceLimits сериализуется, native ResourceLimits не имеет `_dump_data`; поддержка сохранения VM/шаблонов не реализуется этим этапом |
| L03 | `api_visit`; `test_visitor_with_explicit_ruby_nodes`, `test_profile_produces_ruby_tree` | В native AST переменные заменяются placeholders, visitor видит другую структуру. Для анализа дерева предусмотрены явный Ruby fallback и profiler; различие представления не считается отдельным дефектом каждой переменной |
| L04 | `Liquid514SafetyTest#test_positional_filter_argument_boundary` | Чистый Liquid принимает 254/255/256 аргументов; C принимает 254 и отклоняет 255: счётчик аргументов инструкции ограничен байтом |
| L05 | `Liquid514SafetyTest#test_keyword_filter_argument_boundary` | Чистый Liquid принимает 255/256 keyword keys; C отклоняет 256 ключей; существующий предел native-компилятора |
| L06 | `Liquid514SafetyTest#test_variable_render_hook_is_called` | Аналог hook редактора InSales: одинаковое переопределение `Variable#render` вызывается в pure/no_vm/disabled и обходится native VM. Fixture подключается только внутри отдельного процесса; несовместимость не маскируется |


Прочие тесты — полезные проходящие проверки или воспроизведения, которые пока
упираются в R01. Например, тест диапазона 5.14 не доказывает корректность C range
accounting, если его разбор раньше завершился ArgumentError. После будущих исправлений
нужно повторить весь набор: снятие одного барьера может открыть следующие ошибки.

### Генеративные находки

Seed `51400`, случай `10`: `{{ x.last | default: 'D' }}` при строке `éЖ`
возвращает `Ж` в оригинале и `D` в C. Минимизация — `{{ x.last }}`,
закреплённая в `test_string_last`. Случаи с `self.x` сокращены до
`test_self_lookup_in_default_mode`. Условные и циклические шаблоны упираются в R01;
их минимальное воспроизведение — `test_safe_expression_keyword`. Других независимых
причин среди различий этого фиксированного seed не установлено.

## Артефакты и границы результата

Машиночитаемый снимок результатов этого этапа хранится рядом:
[liquid-5.14-results.json](liquid-5.14-results.json).
Полные локальные логи и наблюдения находятся в `tmp/compatibility/`;
CI сохраняет этот каталог как artifact даже при красном результате.
Ruby HTML coverage — `tmp/coverage/ruby/index.html`, native coverage и JSON —
`tmp/coverage/native/`. Эти генерируемые файлы не входят в Git. Coverage-задачи начинают со свежего
Ruby resultset; окно объединения результатов — 24 часа, чтобы длительный
GC/coverage-прогон не терял первые процессы из-за стандартного timeout SimpleCov.

Ruby 3.0/3.1, ruby-head и TruffleRuby сохранены в существующей CI-матрице,
но локально не проверялись. Ruby 3.4 добавлен в матрицу. Windows, macOS,
ppc64el и 32-bit не проверялись. Процент gcov относится к исполняемым строкам
`.c` этой сборки; headers не суммируются повторно по compilation units.
Непокрытые ветви и успешный GC stress не доказывают отсутствие memory bugs.

Порядок следующего этапа: R14 как ошибка тихой порчи результата; затем R01 вместе с R02/R05 и корректным Ruby fallback;
затем R03/R04, Environment и фильтры, лимиты и формат вывода. После каждого
исправления запускать целую матрицу. Результат этого этапа — воспроизводимая
красная база; совместимость гема с 5.14.0 пока не достигнута.

## Итоговые результаты

Во всех четырёх режимах на Ruby 3.2.9, 3.3.0 и 3.4.6 проходят 1062 upstream-теста и 102 новых регрессионных теста **на чистом Liquid**. Таблица ниже показывает strict; все режимы есть в JSON-снимке.

| Ruby | Набор | pure F/E | C F/E | no_vm F/E | disabled F/E |
| --- | --- | --- | --- | --- | --- |
| 3.3.0 | upstream | 0/0 | 64/368 | 38/367 | 26/361 |
| 3.3.0 | regression | 0/0 | 23/30 | 15/25 | 5/20 |
| 3.2.9 | upstream | 0/0 | 64/368 | 38/367 | 26/361 |
| 3.2.9 | regression | 0/0 | 23/30 | 15/25 | 5/20 |
| 3.4.6 | upstream | 0/0 | 73/368 | 38/367 | 26/361 |
| 3.4.6 | regression | 0/0 | 24/30 | 15/25 | 5/20 |

F/E — число failures/errors. Например, 368 errors в upstream C — число падающих тестов, а не 368 независимых багов.

Из 48 safety-процессов проходят 44; четыре красных запуска относятся к C: переполнение constants, два предела аргументов и обход Variable render hook. Все 12 pure-сценариев проходят; сигналов завершения и таймаутов нет. Переполнение constants отдельно подтверждено на Ruby 3.2.9 и 3.4.6.

Сравнительный набор: 2208 сравнений, 474 различия. Генератор: 3072 сравнений, 1147 различий. Здесь также учитываются известные ограничения; разницы сгруппированы в каталоге выше.

Ruby coverage: **91.66% строк / 90.90% ветвей** для `lib/**/*.rb`. C coverage: **92.28% строк / 84.26% ветвей**: 1960/2124 исполняемых строк и 605/718 ветвей в 18 `.c`-файлах. Сборка с coverage и экспорт gcov завершились успешно, тестовые команды вернули ненулевой статус из-за зафиксированных несовместимостей.

Основные непокрытые области: вспомогательные пути assembler/disassembler, отдельные error/cleanup-ветви block/VM и управление пулом assembler. Полная разбивка по файлам есть в JSON. Часть глубоких языковых сценариев пока блокируется R01 до рендеринга.

Проверки runner: 4 теста, 9 assertions, без падений. RuboCop: 21 изменённый Ruby/Rake-файл без замечаний. `git diff --check` проходит.

Исходные 85 тестов C сохранены. На Ruby 3.2/3.3 у них два errors из-за R01; на 3.4 дополнительно остаются два failures: ожидание старого Ruby `Hash#inspect` в отладочном фильтре и точное число TracePoint Ruby calls. Они отделены от семантической регрессии компактного Hash-вывода Liquid (R12).
