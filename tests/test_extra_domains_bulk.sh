#!/bin/sh
# Same transaction guarantees must hold for both editable domain lists.
Z2K_TEST_EXTRA=1 sh "$(dirname "$0")/test_whitelist_bulk.sh"
