# frozen_string_literal: true

RSpec.describe "Directory checks (part 7)" do
  fab!(:member) { Fabricate(:user, username: "viewer_member") }
  fab!(:active) { Fabricate(:user, username: "zoe_active") }
  fab!(:suspended) do
    Fabricate(
      :user,
      username: "zoe_suspended",
      suspended_at: 1.day.ago,
      suspended_till: 1.year.from_now,
    )
  end
  fab!(:was_suspended) do
    Fabricate(
      :user,
      username: "zoe_was_suspended",
      suspended_at: 1.month.ago,
      suspended_till: 1.day.ago,
    )
  end
  fab!(:silenced) { Fabricate(:user, username: "zoe_silenced", silenced_till: 1.year.from_now) }
  fab!(:moderator)
  fab!(:title_field) { Fabricate(:user_field, name: "Title", show_on_profile: true) }

  before do
    # As in part 2's spec: off here so only these parts decide who's listed.
    SiteSetting.hide_new_user_profiles = false
    silenced.user_custom_fields.create!(name: "user_field_#{title_field.id}", value: "CFO")
    DirectoryItem.refresh!
  end

  def usernames
    response.parsed_body["directory_items"].map { |i| i["user"]["username"] }
  end

  context "as a member" do
    before { sign_in(member) }

    it "leaves suspended people out of the directory and its total" do
      get "/directory_items.json", params: { period: "all" }

      expect(usernames).to include("zoe_active", "zoe_was_suspended")
      expect(usernames).not_to include("zoe_suspended")
      expect(response.parsed_body["meta"]["total_rows_directory_items"]).to eq(usernames.size)
    end

    it "gets no staff fields on the rows" do
      get "/directory_items.json", params: { period: "all" }

      expect(response.parsed_body["directory_items"].first).not_to have_key("cardwell_staff")
    end

    it "can't read the silenced list" do
      get "/cardwell/directory/silenced.json"

      expect(response.status).to eq(403)
    end

    it "lists suspended people again when the part is off" do
      SiteSetting.cardwell_directory_checks_enabled = false

      get "/directory_items.json", params: { period: "all" }

      expect(usernames).to include("zoe_suspended")
    end
  end

  context "as staff" do
    before { sign_in(moderator) }

    it "lists suspended people, with their moderation state and visits" do
      suspended.user_stat.update!(days_visited: 4)

      get "/directory_items.json", params: { period: "all" }

      row = response.parsed_body["directory_items"].find { |i| i["id"] == suspended.id }
      expect(row).to be_present
      staff = row["cardwell_staff"]
      expect(Time.zone.parse(staff["suspended_till"])).to be_within(1.second).of(
        suspended.suspended_till,
      )
      expect(staff["silenced_till"]).to be_nil
      expect(Time.zone.parse(staff["created_at"])).to be_within(1.second).of(suspended.created_at)
      expect(staff).to have_key("last_seen_at")
      expect(staff["days_visited"]).to eq(4)
    end

    it "gets the silenced members core leaves out, in the directory's row shape" do
      get "/directory_items.json", params: { period: "all" }
      expect(usernames).not_to include("zoe_silenced")

      get "/cardwell/directory/silenced.json", params: { user_field_ids: title_field.id.to_s }

      expect(response.status).to eq(200)
      rows = response.parsed_body["directory_items"]
      expect(rows.map { |r| r["user"]["username"] }).to eq(["zoe_silenced"])
      row = rows.first
      expect(row["id"]).to eq(silenced.id)
      expect(row["user"]["user_fields"][title_field.id.to_s]["value"]).to eq(["CFO"])
      expect(Time.zone.parse(row["cardwell_staff"]["silenced_till"])).to be_within(1.second).of(
        silenced.silenced_till,
      )
    end

    it "limits the silenced list to a group's members" do
      group = Fabricate(:group, name: "active-members")
      other = Fabricate(:user, username: "zoe_silenced_too", silenced_till: 1.year.from_now)
      group.add(other)

      get "/cardwell/directory/silenced.json", params: { group: "active-members" }

      expect(response.parsed_body["directory_items"].map { |r| r["id"] }).to eq([other.id])
    end

    it "refuses a group that doesn't exist" do
      get "/cardwell/directory/silenced.json", params: { group: "nope" }

      expect(response.status).to eq(400)
    end

    it "answers nothing when the part is off" do
      SiteSetting.cardwell_directory_checks_enabled = false

      get "/directory_items.json", params: { period: "all" }
      expect(response.parsed_body["directory_items"].first).not_to have_key("cardwell_staff")

      get "/cardwell/directory/silenced.json"
      expect(response.status).to eq(404)
    end
  end
end
