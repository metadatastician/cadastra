;; SPDX-License-Identifier: MPL-2.0
;; Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
;;
;; Guix development environment for cadastra — Guix is the estate's sole
;; package manager (hyperpolymath/standards Nix ruling: flakes are removed,
;; not tolerated). This replaces the retired flake.nix and mirrors the
;; toolchain it declared: `just` runs the root Justfile.
;;
;; Usage:
;;   guix shell -D -f guix.scm    # development shell (also direnv `use guix`)
;;   guix build -f guix.scm       # build package

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages base)
             (gnu packages build-tools))

(package
  (name "cadastra")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (native-inputs
   (list just))
  (synopsis "Development environment for cadastra")
  (description "Provides the task-runner toolchain needed to work on this
repository; the root Justfile delegates the build phases.")
  (home-page "https://github.com/metadatastician/cadastra")
  (license mpl2.0))
