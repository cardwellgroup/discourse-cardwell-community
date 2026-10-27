# frozen_string_literal: true

RSpec.describe "Profile hiding (part 2)" do
  fab!(:active_group) { Fabricate(:group, name: "active-members") }
  fab!(:viewer) { Fabricate(:user, username: "viewer_member") }
  fab!(:active) { Fabricate(:user, username: "zoe_active", name: "Zoe Active") }
  fab!(:paused) { Fabricate(:user, username: "zoe_paused", name: "Zoe Paused") }
  fab!(:moderator)
  fab!(:state_group) { Fabricate(:group, name: "state-ohio") }
  fab!(:badge) { Fabricate(:badge, name: "Graduate") }

  # A state group and a badge holding one active and one hidden member, as the
  # Auth sync and the graduation badge will leave them.
  def seed_group_and_badge
    [viewer, active, paused].each { |user| state_group.add(user) }
    Group.reset_user_count(state_group)
    [active, paused].each { |user| BadgeGranter.grant(badge, user) }
  end

  def member_usernames(body)
    body["members"].map { |m| m["username"] }
  end

  def grantee_ids(body)
    body["user_badge_info"]["user_badges"].map { |b| b["user_id"] }
  end

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
      seed_group_and_badge

      get "/u/zoe_paused.json"
      expect(response.parsed_body["user"]["profile_hidden"]).not_to eq(true)

      get "/directory_items.json", params: { period: "all" }
      usernames = response.parsed_body["directory_items"].map { |i| i["user"]["username"] }
      expect(usernames).to include("zoe_paused")

      get "/groups/state-ohio/members.json"
      expect(member_usernames(response.parsed_body)).to include("zoe_paused")
      expect(response.parsed_body["meta"]["total"]).to eq(3)

      get "/groups/state-ohio.json"
      expect(response.parsed_body["group"]["user_count"]).to eq(3)

      get "/user_badges.json", params: { badge_id: badge.id }
      expect(grantee_ids(response.parsed_body)).to include(paused.id)

      get "/badges/#{badge.id}.json"
      expect(response.parsed_body["badge"]["grant_count"]).to eq(2)
    end

    context "with a group and a badge that include a hidden member" do
      before { seed_group_and_badge }

      it "leaves them out of the group's member list and its total" do
        get "/groups/state-ohio/members.json"

        expect(response.status).to eq(200)
        usernames = member_usernames(response.parsed_body)
        expect(usernames).to contain_exactly("viewer_member", "zoe_active")
        expect(response.parsed_body["meta"]["total"]).to eq(2)
      end

      it "leaves them out of a filtered member list too" do
        get "/groups/state-ohio/members.json", params: { filter: "zoe" }

        expect(member_usernames(response.parsed_body)).to contain_exactly("zoe_active")
      end

      it "counts only who is shown, on the group and in the groups list" do
        get "/groups/state-ohio.json"
        expect(response.parsed_body["group"]["user_count"]).to eq(2)

        get "/groups.json"
        listed = response.parsed_body["groups"].find { |g| g["name"] == "state-ohio" }
        expect(listed["user_count"]).to eq(2)
      end

      it "leaves them out of the group's owners" do
        state_group.add_owner(paused)

        get "/groups/state-ohio/members.json"

        expect(response.parsed_body["owners"].map { |o| o["username"] }).to be_empty
      end

      it "leaves the group unfiltered outside a members request" do
        expect(state_group.listed_users).to include(paused)
      end

      it "leaves them out of the badge's list of who has it" do
        get "/user_badges.json", params: { badge_id: badge.id }

        expect(response.status).to eq(200)
        expect(grantee_ids(response.parsed_body)).to contain_exactly(active.id)
      end

      # The badge page loads more until it has listed grant_count rows, so a
      # raw count here would leave its spinner up for good.
      it "counts only who is shown, on the badge and in the badges list" do
        get "/badges/#{badge.id}.json"
        expect(response.parsed_body["badge"]["grant_count"]).to eq(1)

        get "/badges.json"
        listed = response.parsed_body["badges"].find { |b| b["id"] == badge.id }
        expect(listed["grant_count"]).to eq(1)
      end

      it "refuses the badge's RSS feed of grantees" do
        get "/badges/#{badge.id}.rss"

        expect(response.status).to eq(404)
      end
    end
  end

  context "as a hidden member" do
    before { sign_in(paused) }

    it "still shows them their own profile" do
      get "/u/zoe_paused.json"

      expect(response.parsed_body["user"]["profile_hidden"]).not_to eq(true)
      expect(response.parsed_body["user"]["bio_raw"]).to eq("A bio nobody should see")
    end

    it "still lists them in their own group" do
      seed_group_and_badge

      get "/groups/state-ohio/members.json"

      expect(member_usernames(response.parsed_body)).to include("zoe_paused")
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

    it "shows everyone in groups and badges, with the full counts" do
      seed_group_and_badge

      get "/groups/state-ohio/members.json"
      expect(member_usernames(response.parsed_body)).to include("zoe_paused")
      expect(response.parsed_body["meta"]["total"]).to eq(3)

      get "/groups/state-ohio.json"
      expect(response.parsed_body["group"]["user_count"]).to eq(3)

      get "/user_badges.json", params: { badge_id: badge.id }
      expect(grantee_ids(response.parsed_body)).to include(paused.id)

      get "/badges/#{badge.id}.json"
      expect(response.parsed_body["badge"]["grant_count"]).to eq(2)

      get "/badges/#{badge.id}.rss"
      expect(response.status).to eq(200)
      expect(response.body).to include("zoe_paused")
    end
  end
end
