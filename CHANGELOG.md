# Changelog

## [0.1.11](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.10...v0.1.11) (2026-02-11)


### Features

* enhance request cancellation and redelivery logic ([#31](https://github.com/williamwinkler/openai-batch-manager/issues/31)) ([111c6ac](https://github.com/williamwinkler/openai-batch-manager/commit/111c6ac4bfd377df116317001dc497195619139c))

## [0.1.10](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.9...v0.1.10) (2026-02-11)


### Bug Fixes

* make request custom_id constraint unique ([#29](https://github.com/williamwinkler/openai-batch-manager/issues/29)) ([f851967](https://github.com/williamwinkler/openai-batch-manager/commit/f8519673287e0bb48aa8d949bf835834a73523ce))

## [0.1.9](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.8...v0.1.9) (2026-02-11)


### Features

* add endpoints to GET and redeliver requests + retries on delivery ([74143ea](https://github.com/williamwinkler/openai-batch-manager/commit/74143eaeff5a1b3a26d8ad1c51064b26485fe712))

## [0.1.8](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.7...v0.1.8) (2026-02-08)


### Features

* add rabbitmq disconnected/connected status feedback ([#25](https://github.com/williamwinkler/openai-batch-manager/issues/25)) ([fe299e9](https://github.com/williamwinkler/openai-batch-manager/commit/fe299e99a5ea06185534192159b3375a8f5d07fd))

## [0.1.7](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.6...v0.1.7) (2026-02-07)


### Bug Fixes

* batches breadcrumb button go to /batches ([#22](https://github.com/williamwinkler/openai-batch-manager/issues/22)) ([526b797](https://github.com/williamwinkler/openai-batch-manager/commit/526b797d665da83162a3655d678ef9d112c7ef85))
* db connection pool issue during deliver ([#24](https://github.com/williamwinkler/openai-batch-manager/issues/24)) ([958573f](https://github.com/williamwinkler/openai-batch-manager/commit/958573fbdd8c49e4014963b05e1f5668eb5c6c6d))

## [0.1.6](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.5...v0.1.6) (2026-02-06)


### Bug Fixes

* broken ui links and swagger server port ([#20](https://github.com/williamwinkler/openai-batch-manager/issues/20)) ([1c72fbf](https://github.com/williamwinkler/openai-batch-manager/commit/1c72fbf4a7192d89641d48d365db38855daf46c0))

## [0.1.5](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.4...v0.1.5) (2026-02-06)


### Bug Fixes

* build arm runner name in pipeline ([#18](https://github.com/williamwinkler/openai-batch-manager/issues/18)) ([444ebda](https://github.com/williamwinkler/openai-batch-manager/commit/444ebdaa1ed5044dfa21ba2e7e7176716278410c))

## [0.1.4](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.3...v0.1.4) (2026-02-06)


### Bug Fixes

* issue in readme ([#16](https://github.com/williamwinkler/openai-batch-manager/issues/16)) ([9c1a881](https://github.com/williamwinkler/openai-batch-manager/commit/9c1a881fec3168de2edb498d5a08138ae8434eb1))

## [0.1.3](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.2...v0.1.3) (2026-02-06)


### Bug Fixes

* readme docker run cmd ([#12](https://github.com/williamwinkler/openai-batch-manager/issues/12)) ([10a844f](https://github.com/williamwinkler/openai-batch-manager/commit/10a844f2301b68aaf26be63233ecd74927c0e427))

## [0.1.2](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.1...v0.1.2) (2026-02-01)


### Features

* prepare for public ([#9](https://github.com/williamwinkler/openai-batch-manager/issues/9)) ([484e86a](https://github.com/williamwinkler/openai-batch-manager/commit/484e86a2cbc5374ad4615711b8958818355e3ad2))

## [0.1.1](https://github.com/williamwinkler/openai-batch-manager/compare/v0.1.0...v0.1.1) (2026-02-01)


### Features

* add expires_at for batches + auto deletion ([7153a77](https://github.com/williamwinkler/openai-batch-manager/commit/7153a77ae62a8245231fe57b6d779d5206c59ed1))
* auto reschedule expired batches ([a8e1e66](https://github.com/williamwinkler/openai-batch-manager/commit/a8e1e66d1adf72534a2503519885c473a3ea4ab8))
* **batch:** add cleanup after destroy or cancel ([c1dad8b](https://github.com/williamwinkler/openai-batch-manager/commit/c1dad8b14ffdd092b448900f84d565d6c4546772))
* creating a batch now creates a batch_&lt;id&gt;.jsonl file ([70932f2](https://github.com/williamwinkler/openai-batch-manager/commit/70932f2b7895e4a19d1b73741232a756838af577))
* deliver via rabbitmq ([dcc497f](https://github.com/williamwinkler/openai-batch-manager/commit/dcc497f2af1f683e4d194786305753f0f45725f8))
