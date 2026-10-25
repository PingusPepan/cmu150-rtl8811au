# Changelog

## 1.0.0 (2026-10-25)


### Features

* **usb:** add Archer T2U IDs, drop calls this kernel does not export ([d9659b6](https://github.com/PingusPepan/cmu150-rtl8811au/commit/d9659b6eb73e41b6f20f6893d2189f53c6c17344))


### Bug Fixes

* **ap:** enter the mlme-EXT AP state in start_bss_network ([1d56941](https://github.com/PingusPepan/cmu150-rtl8811au/commit/1d56941a7474ee69a33cd6858f73924f169568e9))
* **cfg80211:** advertise AP SME, set custom regd before register ([5da662a](https://github.com/PingusPepan/cmu150-rtl8811au/commit/5da662af080beeb50b27f5e418868627761dfd5c))
* **mlme:** restore Realtek's WIFI_AUTH fallthrough in mgt_dispatcher ([f2377da](https://github.com/PingusPepan/cmu150-rtl8811au/commit/f2377dae5b88f6fea9100fa9b6b0abd92454f3b0))
* **osdep:** keep USB autosuspend off ([c5cc136](https://github.com/PingusPepan/cmu150-rtl8811au/commit/c5cc136250095e346491eec7c42c259c92b4c2b7))
* **regd:** keep 5 GHz UNII-1 beaconable ([486a0ab](https://github.com/PingusPepan/cmu150-rtl8811au/commit/486a0ab551818fa0701cbbdeb0e4f0da71288919))


### Build

* **makefile:** add the CMU150 platform target ([11c44e9](https://github.com/PingusPepan/cmu150-rtl8811au/commit/11c44e95412c4a477870c5d7018e699c3c039e0d))


### Miscellaneous

* add build harness, installer, docs and CI ([f490ae2](https://github.com/PingusPepan/cmu150-rtl8811au/commit/f490ae21b0070c01b051e129bf91b6606341cddf))
