#!/usr/bin/env bash

for package in concurrency dejafu hunit-dejafu tasty-dejafu; do
  # brittany messes up the cpp in Control.Monad.{Conc,STM}.Class
  if [[ "$package" != "concurrency" ]]; then
    find $package -name '*.hs' -exec brittany --config-file .brittany.conf --write-mode inplace {} \;
  fi
  find $package -name '*.hs' -exec stylish-haskell -i {} \;
done
