defmodule Librarian.BucketTest do
  use ExUnit.Case, async: true

  alias Librarian.Bucket

  describe "parse/1" do
    test "2-part legacy form" do
      assert { "u", nil, "research" } = Bucket.parse("u:research")
    end

    test "3-part future form" do
      assert { "User_A", "Project_ABC", "Research" } =
               Bucket.parse("User_A:Project_ABC:Research")
    end

    test "bare name" do
      assert { nil, nil, "inbox" } = Bucket.parse("inbox")
    end

    test "unexpected garbage (3-ish part) hits 3-part branch" do
      # "weird::" -> split on ":" -> ["weird", "", "", ""] -> [u, p, n]
      # (a 4-empty-element list matches the 3-part pattern first)
      assert { nil, nil, "weird:::" } = Bucket.parse("weird:::")
    end
  end

  describe "format/3" do
    test "nil project emits legacy form (byte-identical)" do
      assert "u:research" = Bucket.format("u", nil, "research")
    end

    test "project included emits 3-tier form" do
      assert "User_A:Project_ABC:Research" =
               Bucket.format("User_A", "Project_ABC", "Research")
    end

    test "roundtrip: format then parse is stable" do
      key = Bucket.format("User_A", "Project_ABC", "Research")
      assert { "User_A", "Project_ABC", "Research" } = Bucket.parse(key)
    end
  end

  describe "segment accessors" do
    test "user_of" do
      assert "u" = Bucket.user_of("u:proj:research")
      assert "u" = Bucket.user_of("u:research")
      assert is_nil(Bucket.user_of("research"))
    end

    test "project_of (nil wildcard)" do
      assert is_nil(Bucket.project_of("u:research"))
      assert "Project_ABC" = Bucket.project_of("User_A:Project_ABC:Research")
    end

    test "name_of" do
      assert "Research" = Bucket.name_of("User_A:Project_ABC:Research")
      assert "research" = Bucket.name_of("u:research")
    end
  end

  describe "regression: exact user match, no prefix bleed" do
    test "user_of treats project segment as NOT part of user" do
      # Under the future 3-tier scheme, the user is the FIRST segment only.
      # A naive `starts_with?("User_A:")` check would also wrongly
      # sweep in `User_A:Project_ABC` if that were ever a user key.
      assert Bucket.user_of("User_A:Project_ABC:Research") == "User_A"
      refute Bucket.user_of("User_A:Project_ABC:Research") == "User_A:Project_ABC"
    end

    test "all_for_user-style filter is exact, not prefix" do
      buckets = [
        "User_A:Project_ABC:Research",
        "User_A:Project_XYZ:Research",
        "User_B:Project_ABC:Research"
      ]

      mine = Enum.filter(buckets, &(Bucket.user_of(&1) == "User_A"))
      assert length(mine) == 2
      refute Enum.any?(mine, &(&1 == "User_B:Project_ABC:Research"))
    end
  end
end
