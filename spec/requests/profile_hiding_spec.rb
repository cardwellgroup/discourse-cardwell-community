# frozen_string_literal: true

RSpec.describe "Profile hiding (part 2)" do
  fab!(:active_group) { Fabricate(:group, name: "active-members") }
  fab!(:viewer) { Fabricate(:user, username: "viewer_member") }
  fab!(:active) { Fabricate(:user, username: "zoe_active", name: "Zoe Active") }
  fab!(:paused) { Fabricate(:user, username: "zoe_paused", name: "Zoe Paused") }
  fab!(:moderator)

  before do
    # Core hides new members' profiles (no posts, low trust) on sites that are
    # neither invite-only nor approval-required. The community is both, so
    # that rule never applies there; off here so only this part hides anyone.
    SiteSetting.hide_new_user_profiles = false
    active_group.add(viewer)
    active_group.add(active)
    paused.user_profile.update!(bio_raw: "A bio nobody should see")
    SiteSetting.cardwell_active_member_groups = active_group.id.to_s
  end

  context "as a member" do
    before { sign_in(viewer) }
    after { SearchIndexer.disable }

    it "answers a hidden profile with name, username and photo only" do
      get "/u/zoe_paused.json"

      expect(response.status).to eq(200)
      user = response.parsed_body["user"]
      expect(user["profile_hidden"]).to eq(true)
      expect(user["name"]).to eq("Zoe Paused")
      expect(user["avatar_template"]).to be_present
      expect(user).not_to have_key("bio_raw")
      expect(user).not_to have_key("bio_cooked")
    end

    it "answers the user card the same way" do
      get "/u/zoe_paused/card.json"

      expect(response.parsed_body["user"]["profile_hidden"]).to eq(true)
    end

    it "shows an active member's profile as usual" do
      get "/u/zoe_active.json"

      expect(response.parsed_body["user"]["profile_hidden"]).not_to eq(true)
    end

    it "leaves a hidden member out of the batch card request" do
      get "/user-cards.json", params: { user_ids: [active.id, paused.id].join(",") }

      usernames = response.parsed_body["users"].map { |u| u["username"] }
      expect(usernames).to include("zoe_active")
      expect(usernames).not_to include("zoe_paused")
    end

    it "leaves a hidden member out of the directory" do
      DirectoryItem.refresh!

      get "/directory_items.json", params: { period: "all" }

      usernames = response.parsed_body["directory_items"].map { |i| i["user"]["username"] }
      expect(usernames).to include("zoe_active", "viewer_member")
      expect(usernames).not_to include("zoe_paused")
      expect(response.parsed_body["meta"]["total_rows_directory_items"]).to eq(usernames.size)
    end

    it "skips a hidden member in @mention suggestions" do
      get "/u/search/users.json", params: { term: "zoe_" }

      usernames = response.parsed_body["users"].map { |u| u["username"] }
      expect(usernames).to include("zoe_active")
      expect(usernames).not_to include("zoe_paused")
    end

    it "leaves a hidden member out of header and full-page search" do
      SearchIndexer.enable
      [active, paused].each { |user| SearchIndexer.index(user, force: true) }

      get "/search/query.json", params: { term: "zoe" }

      usernames = response.parsed_body["users"].map { |u| u["username"] }
      expect(usernames).to include("zoe_active")
      expect(usernames).not_to include("zoe_paused")
    end

    it "finds active members in header search even when hidden ones rank first" do
      SearchIndexer.enable
      hidden =
        (1..6).map do |n|
          Fabricate(:user, username: "zoe_hidden_#{n}", last_posted_at: n.minutes.ago)
        end
      active.update!(last_posted_at: 1.year.ago)
      [active, *hidden].each { |user| SearchIndexer.index(user, force: true) }

      get "/search/query.json", params: { term: "zoe" }

      usernames = response.parsed_body["users"].map { |u| u["username"] }
      expect(usernames).to include("zoe_active")
      expect(usernames.grep(/zoe_hidden/)).to be_empty
    end

    it "hides nobody while the active group is empty" do
      SiteSetting.cardwell_active_member_groups = ""
      DirectoryItem.refresh!

      get "/u/zoe_paused.json"
      expect(response.parsed_body["user"]["profile_hidden"]).not_to eq(true)

      get "/directory_items.json", params: { period: "all" }
      usernames = response.parsed_body["directory_items"].map { |i| i["user"]["username"] }
      expect(usernames).to include("zoe_paused")
    end
  end

  context "as a hidden member" do
    before { sign_in(paused) }

    it "still shows them their own profile" do
      get "/u/zoe_paused.json"

      expect(response.parsed_body["user"]["profile_hidden"]).not_to eq(true)
      expect(response.parsed_body["user"]["bio_raw"]).to eq("A bio nobody should see")
    end
  end

  context "as staff" do
    before { sign_in(moderator) }

    it "shows everyone, everywhere" do
      DirectoryItem.refresh!

      get "/u/zoe_paused.json"
      expect(response.parsed_body["user"]["profile_hidden"]).not_to eq(true)

      get "/directory_items.json", params: { period: "all" }
      usernames = response.parsed_body["directory_items"].map { |i| i["user"]["username"] }
      expect(usernames).to include("zoe_paused")

      get "/u/search/users.json", params: { term: "zoe_" }
      usernames = response.parsed_body["users"].map { |u| u["username"] }
      expect(usernames).to include("zoe_paused")

      SearchIndexer.enable
      SearchIndexer.index(paused, force: true)
      get "/search/query.json", params: { term: "zoe" }
      usernames = response.parsed_body["users"].map { |u| u["username"] }
      expect(usernames).to include("zoe_paused")
    ensure
      SearchIndexer.disable
    end
  end
end
