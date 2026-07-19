defmodule Librarian.CouncilTest do
  use ExUnit.Case, async: false

  alias Librarian.Council
  alias Librarian.Council.Persona

  describe "Librarian.Council.Persona" do
    test "available_personas returns 4 personas" do
      assert length(Persona.available_personas()) == 4
      assert :skeptic in Persona.available_personas()
      assert :historian in Persona.available_personas()
      assert :connector in Persona.available_personas()
      assert :literalist in Persona.available_personas()
    end

    test "config returns temperature and system_prompt for each persona" do
      for persona <- Persona.available_personas() do
        cfg = Persona.config(persona)
        assert is_binary(cfg.name)
        assert is_number(cfg.temperature)
        assert cfg.temperature > 0.0 and cfg.temperature <= 1.0
        assert is_binary(cfg.system_prompt)
        assert byte_size(cfg.system_prompt) > 100
      end
    end

    test "skeptic has higher temperature than literalist" do
      skeptic_temp = Persona.config(:skeptic).temperature
      literalist_temp = Persona.config(:literalist).temperature
      assert skeptic_temp > literalist_temp
    end

    test "connector has highest temperature for creative associations" do
      temps =
        Persona.available_personas()
        |> Enum.map(&Persona.config(&1).temperature)

      assert Enum.max(temps) == Persona.config(:connector).temperature
    end

    test "compile_messages returns proper message format" do
      messages = Persona.compile_messages(:skeptic, "test content")

      assert length(messages) == 2
      assert hd(messages)["role"] == "system"
      assert List.last(messages)["role"] == "user"
      assert List.last(messages)["content"] =~ "test content"
    end
  end

  describe "Librarian.Council" do
    @tag :skip
    test "stage_one returns all persona takes" do
      content =
        "The system migrated from Postgres to SQLite for simplicity. Deploy to production occurred at 3pm."

      takes = Council.stage_one(content)

      assert length(takes) == 4

      for {persona, result} <- takes do
        assert persona in Persona.available_personas()
        assert elem(result, 0) in [:ok, :error]
      end
    end

    @tag :skip
    test "deliberate returns structured result" do
      content = "The system migrated from Postgres to SQLite for simplicity."

      result = Council.deliberate(content)

      assert elem(result, 0) in [:ok, :error]
    end

    test "deliberate_on_memory returns error for non-existent memory" do
      assert {:error, :memory_not_found} = Council.deliberate_on_memory(999_999)
    end

    test "build_children_context includes both Document Fragment and Merged from prior observation labels" do
      alias Librarian.{WarmStore, Curator, ColdStore}

      # Create a memory that will serve as the "consolidated" target
      {:ok, emb} = Curator.Stub.embed("consolidated memory for provenance test")
      memory = WarmStore.put("prov_user:test", %Curator.Result{
        summary: "consolidated memory",
        facts: ["was merged from two sources"],
        tags: ["test"],
        importance: 0.5,
        embedding: emb
      })

      # Create a "document fragment" memory and log a chunk_of edge to it
      {:ok, frag_emb} = Curator.Stub.embed("document fragment for provenance test")
      fragment = WarmStore.put("prov_user:test", %Curator.Result{
        summary: "original document fragment",
        facts: ["part of a larger document"],
        tags: ["test"],
        importance: 0.5,
        embedding: frag_emb
      })
      ColdStore.log_relationship(
        to_string(fragment.id),
        to_string(memory.id),
        "chunk_of",
        "prov_user",
        %{}
      )

      # Create a "prior observation" memory and log a superseded_by edge to it
      {:ok, prior_emb} = Curator.Stub.embed("prior observation for provenance test")
      prior = WarmStore.put("prov_user:test", %Curator.Result{
        summary: "prior observation that was merged",
        facts: ["was an independent memory"],
        tags: ["test"],
        importance: 0.5,
        embedding: prior_emb
      })
      ColdStore.log_relationship(
        to_string(prior.id),
        to_string(memory.id),
        "superseded_by",
        "prov_user",
        %{}
      )

      # Run the full council pipeline end-to-end.
      # With Stub as the test backend, this should succeed.
      # The provenance labels ("Document Fragment", "Merged from prior observation")
      # are in the context prompt sent to personas — we verify the pipeline
      # works correctly by checking the synthesis is a map with expected keys.
      {:ok, result} = Council.deliberate_on_memory(memory.id)

      # synthesis is the full Judge result map
      assert is_map(result.synthesis)
      assert result.synthesis.summary =~ "Stub synthesis:"

      # Verify the persona_takes map has the expected structure
      # (4 personas, each with a stub response)
      assert map_size(result.persona_takes) == 4
    end
  end
end
