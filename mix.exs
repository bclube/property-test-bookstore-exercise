defmodule Bookstore.MixProject do
  use Mix.Project

  def project do
    [
      app: :bookstore,
      version: "0.1.0",
      elixir: "~> 1.9",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript_config()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Bookstore.App, []},
      env: [
        pg: [
          user: System.get_env("DB_ENV_POSTGRES_USER") |> String.to_charlist(),
          password: System.get_env("DB_ENV_POSTGRES_PASSWORD") |> String.to_charlist(),
          database: 'bookstore_db',
          host: System.get_env("DB_ENV_POSTGRES_HOST") |> String.to_charlist(),
          port: 5432,
          ssl: ssl(Mix.env())
        ]
      ]
    ]
  end

  defp ssl(env) when env in [:dev, :test], do: false
  defp ssl(_), do: true

  defp deps do
    [
      {:eql, "~> 0.1.2"},
      {:pgsql, "~> 26.0"},
      {:propcheck, "~> 1.1", only: [:test, :dev]}
    ]
  end

  defp escript_config do
    [main_module: Bookstore.Init, app: nil]
  end
end
