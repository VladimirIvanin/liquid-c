# Воспроизводимые измерения liquid-c

Цель — Ruby 3.2 без YJIT и без Liquid Profiler. GC включён. Сценарии используют локальный `fixtures.json` и отдельно измеряют parse, render и parse+render; JSONL содержит образцы, медиану, разброс, аллокации и RSS.

```sh
mkdir -p docs/bench
DEBUG=false bundle exec rake compile
REPEATS=5 BATCH_SECONDS=0.3 bundle exec ruby --disable-yjit -Ilib performance/measure.rb > docs/bench/current.jsonl
bundle exec ruby performance/compare.rb docs/bench/baseline.jsonl docs/bench/current.jsonl
```

Для парного сравнения с отдельной сборкой `21c3d74` на том же Ruby:

```sh
ruby performance/run_comparison.rb BASE_EXTENSION BASE_LIBRARY CURRENT_EXTENSION docs/bench/comparison
```

BASE_LIBRARY должен содержать Ruby-обвязку соответствующей baseline-сборки без другого liquid_c.so. Не смешивайте ABI и версии обвязки. `BENCH_SCENARIOS=variables,unique` ограничивает группу, `EDITOR_PATCH=true` применяет editor hook к обоим вариантам, `BENCH_ENGINE=pure` выбирает Ruby Liquid. YJIT включается только явным `BENCH_YJIT=true`; такие измерения не являются целевыми.

`build_stage_baseline.rb` строит промежуточную ступень исправлений безопасности без новых frontend. Измерять варианты последовательно, без параллельных тестов и сборок, с одинаковым Ruby/JIT и минимум пятью повторами. RSS — накопительный VmHWM процесса. Небольшая разница при пересечении диапазонов не доказывает ускорения.

Результаты и исследовательские отчёты хранить в игнорируемой `docs/`, не добавлять в Git.

## Изолированное сравнение четырёх движков

Нужны исходники Liquid 4.0.4, liquid-c 4.0.1 и Liquid 5.14.0, а также
зависимости benchmark на выбранном Ruby. Скрипт создаёт отдельные снимки и
release-сборки для старого расширения, ревизии `6d66f63` и рабочего дерева.
Ruby-обвязка каждого расширения берётся из соответствующего снимка.

```sh
ruby --disable-yjit performance/build_cross_engines.rb \
  --liquid4 /path/to/liquid-4.0.4 \
  --liquid-c4 /path/to/liquid-c-4.0.1 \
  --liquid5 /path/to/liquid-5.14.0 \
  --output tmp/cross-engines
ruby --disable-yjit performance/cross_compare.rb \
  tmp/cross-engines/engines.json docs/bench/series-1 theme
REVERSE_ORDER=true ruby --disable-yjit performance/cross_compare.rb \
  tmp/cross-engines/engines.json docs/bench/series-2 theme
ruby --disable-yjit performance/cross_compare.rb \
  tmp/cross-engines/engines.json docs/bench/fixtures fixtures
```

По умолчанию используются `warn`, номера строк, две секунды прогрева и семь
образцов по секунде на каждую операцию. GC включён, profiler выключен. Прогоны
последовательные; во время измерений не запускать тесты, сборку и другие
benchmarks. `ERROR_MODE`, `REPEATS`, `WARMUP`, `BATCH_SECONDS` позволяют менять
протокол; короткие серии служат только для исследования. Разброс свыше 5%
требует выяснения причины и повторной серии.

В JSONL сохраняются исходные образцы, медиана, разброс, аллокации, GC, RSS,
версии, ревизии, хэши исходников и бинарников, параметры сборки и хэш корпуса.
Обёртка проверяет путь загруженного расширения. HTML ThemeRunner сохраняется
целиком; его совпадение между движками проверяется вне измеряемого участка.
Страница и layout разбираются отдельно. Фиксированный корпус и лицензия лежат
в `theme/`. Дополнительный корпус использует общие `workloads.rb` и
`fixtures.json`; после `fixtures` можно указать подстроки имён сценариев.
Несовместимые с Liquid 4 сценарии следует сравнивать отдельным manifest
с конфигурациями Liquid 5.

## Паттерны Fleur в ThemeRunner

`THEME_CORPUS=fleur` включает отдельные сценарии по мотивам темы Fleur;
`all` запускает также прежний набор, а значение по умолчанию `original`
сохраняет его отдельно. Это синтетические паттерны, а не полный рендер темы:
реализации `widget`, `paginate`, `yield` и прочих расширений не подменяются
заглушками. Ссылки на исходники зафиксированной ревизии находятся в фикстурах.

В набор входят карточки с 4/12 вариантами товара, вложенными include и
арифметическими фильтрами; таблица динамических свойств; цепочка map/sort/join;
24 вызова общего SVG-сниппета; слайдер с внешним forloop и присваиваниями из include.
Каждый сценарий выполняется на Hash и на простых Liquid::Drop. Эти Drops
проверяют протокол доступа, но не имитируют запросы к БД или прикладные Drops.
Ожидаемый HTML вычисляется независимо в Ruby. Перед измерением проверяются
base → alternate → base на одном шаблоне и кэше сниппетов; вывод содержит также
значения присваиваний и проверку восстановления forloop/затенения аргументов.

```sh
CHECK_ONLY=1 THEME_CORPUS=fleur ruby --disable-yjit performance/cross_compare.rb \
  tmp/cross-engines/engines.json docs/bench/fleur-check theme
THEME_CORPUS=fleur ruby --disable-yjit performance/cross_compare.rb \
  tmp/cross-engines/engines.json docs/bench/fleur-series-1 theme
THEME_CORPUS=fleur REVERSE_ORDER=true ruby --disable-yjit performance/cross_compare.rb \
  tmp/cross-engines/engines.json docs/bench/fleur-series-2 theme
```

После `theme` можно указать подстроки имён Fleur-сценариев, например `svg` или
`cards_variants_12x12`. `FLEUR_DATA=hash` или `drop` выбирает один тип данных.
Фазы Fleur по умолчанию:

- `parse`: только корневой шаблон.
- `parse_all`: корень и каждый объявленный сниппет по одному разу, с отдельными
  контекстами разбора; это статический корпус, не обнаружение зависимостей.
- `render`: готовый корень, новый кэш сниппетов на каждый запрос; разбор include
  входит в измерение.
- `render_warm_partials`: готовый корень и прогретые разобранные сниппеты;
  остальные регистры запроса создаются заново.
- `run` (в JSONL `parse_render`): разбор корня и рендер с холодными сниппетами.

HTML записывается в `fleur-outputs-*.json`. В JSONL есть отдельные имена сценариев,
тип данных, режим кэша, хэши фикстур и независимого ожидаемого HTML. Не объединяйте
эти результаты со старыми числами `theme` в один балл без заданных весов трафика.
`CHECK_ONLY=1` выполняет проверки без измерений; записи имеют `mode=verify`.
