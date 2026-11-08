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
