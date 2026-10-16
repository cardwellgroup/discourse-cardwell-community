# frozen_string_literal: true

RSpec.describe CardwellCommunity::ProfileHiding do
  fab!(:active_group) { Fabricate(:group, name: "active-members") }
  fab!(:team) { Fabricate(:group, name: "cardwell-team") }
  fab!(:viewer, :user)
  fab!(:active) { Fabricate(:user, username: "zoe_active") }
  fab!(:paused) { Fabricate(:user, username: "zoe_paused") }
  fab!(:teammate, :user)
  fab!(:moderator)
  fab!(:admin)

  before do
    active_group.add(viewer)
    active_group.add(active)
    team.add(teammate)
    SiteSetting.cardwell_active_member_groups = active_group.id.to_s
    SiteSetting.cardwell_profile_hiding_exempt_groups = team.id.to_s
  end

  def can_see?(viewer, user)
    Guardian.new(viewer).can_see_profile?(user)
  end

  it "hides a member outside the active group from other members" do
    expect(can_see?(viewer, active)).to eq(true)
    expect(can_see?(viewer, paused)).to eq(false)
  end

  it "hides nobody while the active group is empty" do
    SiteSetting.cardwell_active_member_groups = ""

    expect(can_see?(viewer, paused)).to eq(true)
  end

  it "hides nobody while the plugin is off" do
    SiteSetting.cardwell_community_enabled = false

    expect(can_see?(viewer, paused)).to eq(true)
  end

  it "always shows someone their own profile" do
    expect(can_see?(paused, paused)).to eq(true)
  end

  it "shows staff everyone" do
    expect(can_see?(moderator, paused)).to eq(true)
    expect(can_see?(admin, paused)).to eq(true)
  end

  it "never hides staff, the exempt groups or Discourse's bots" do
    expect(can_see?(viewer, moderator)).to eq(true)
    expect(can_see?(viewer, admin)).to eq(true)
    expect(can_see?(viewer, teammate)).to eq(true)
    expect(can_see?(viewer, Discourse.system_user)).to eq(true)
  end

  it "lets a hidden member see the active members" do
    expect(can_see?(paused, active)).to eq(true)
  end

  it "still leaves out what core already hides" do
    expect(Guardian.new(viewer).can_see_profile?(nil)).to eq(false)
  end

  it "asks the database once per person for one guardian" do
    guardian = Guardian.new(viewer)
    guardian.can_see_profile?(paused)

    queries = track_sql_queries { guardian.can_see_profile?(paused) }

    expect(queries.grep(/group_users/)).to be_empty
  end

  describe ".filter_users" do
    it "keeps the same people the profile rule keeps" do
      users = described_class.filter_users(User.real, Guardian.new(viewer))

      expect(users).to include(viewer, active, teammate, moderator, admin)
      expect(users).not_to include(paused)
    end

    it "leaves the list alone for staff" do
      expect(described_class.filter_users(User.real, Guardian.new(moderator))).to include(paused)
    end
  end
end
