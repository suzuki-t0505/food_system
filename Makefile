.PHONY: setup setup_for_docker_user check
.DEFAULT_GOAL := setup

setup:
	docker compose run -w /work/assets --rm food_vault_web npm i
	docker compose run --rm food_vault_web mix setup
	docker compose run -w /work/assets --rm food_ship_web npm i
	docker compose run --rm food_ship_web mix setup

mix_compile:
	docker compose run --rm food_vault_web mix compile --warnings-as-errors --force
	docker compose run --rm food_ship_web mix compile --warnings-as-errors --force

mix_format:
	docker compose run --rm food_vault_web mix format
	docker compose run --rm food_ship_web mix format

mix_credo:
	docker compose run --rm food_vault_web mix credo --all
	docker compose run --rm food_ship_web mix credo --all

mix_test:
	docker compose run --rm food_vault_web mix test
	docker compose run --rm food_ship_web mix test

mix_test_cover:
	docker compose run --rm food_vault_web mix test --cover
	docker compose run --rm food_ship_web mix test --cover

mix_clean:
	docker compose run --rm food_vault_web mix clean
	docker compose run --rm food_ship_web mix clean

mix_reset_db:
	docker compose run --rm food_vault_web mix ecto.reset
	docker compose run --rm food_ship_web mix ecto.reset

check: mix_compile mix_format mix_credo mix_test
