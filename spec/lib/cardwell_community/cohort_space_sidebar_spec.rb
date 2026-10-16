# frozen_string_literal: true

RSpec.describe CardwellCommunity::CohortSpaceSidebar do
  fab!(:cohort) { Fabricate(:group, name: "cohort-a") }
  fab!(:other_cohort) { Fabricate(:group, name: "cohort-b") }
  fab!(:member, :user)
  fab!(:space) { Fabricate(:category, name: "Cohort A space") }
  fab!(:other_space) { Fabricate(:category, name: "Cohort B space") }
  fab!(:plain_category, :category)

  before do
    space.set_permissions(cohort => :full, Group::AUTO_GROUPS[:moderators] => :full)
    space.save!
    other_space.set_permissions(other_cohort => :full)
    other_space.save!
    SiteSetting.cardwell_cohort_space_categories = "#{space.id}|#{other_space.id}"
  end

  def sidebar_ids(user)
    SidebarSectionLink.where(user_id: user.id, linkable_type: "Category").pluck(:linkable_id)
  end

  describe "joining a group" do
    it "puts the group's cohort space in the new member's sidebar" do
      cohort.add(member)

      expect(sidebar_ids(member)).to include(space.id)
      expect(sidebar_ids(member)).not_to include(other_space.id)
    end

    it "adds nothing for a category that isn't listed as a cohort space" do
      plain_category.set_permissions(cohort => :full)
      plain_category.save!

      cohort.add(member)

      expect(sidebar_ids(member)).not_to include(plain_category.id)
    end

    it "doesn't add a space twice" do
      cohort.add(member)
      cohort.remove(member)
      SidebarSectionLink.create!(
        user_id: member.id,
        linkable_type: "Category",
        linkable_id: space.id,
      )

      cohort.add(member)

      expect(sidebar_ids(member).count(space.id)).to eq(1)
    end

    it "skips staged users" do
      staged = Fabricate(:staged)

      cohort.add(staged)

      expect(sidebar_ids(staged)).to be_empty
    end
  end

  describe "staff" do
    it "gives a moderator no cohort spaces through the moderators group" do
      moderator = Fabricate(:moderator)

      expect(sidebar_ids(moderator)).not_to include(space.id)
    end

    it "skips the moderators group even when someone is added to it directly" do
      Group[:moderators].add(member)

      expect(sidebar_ids(member)).not_to include(space.id)
    end

    it "gives a staff member in a cohort group that one space" do
      moderator = Fabricate(:moderator)

      cohort.add(moderator)

      expect(sidebar_ids(moderator)).to include(space.id)
      expect(sidebar_ids(moderator)).not_to include(other_space.id)
    end
  end

  describe "leaving a group" do
    it "takes the space out of the sidebar" do
      cohort.add(member)

      cohort.remove(member)

      expect(sidebar_ids(member)).not_to include(space.id)
    end

    it "keeps the space when another group still gives access" do
      space.set_permissions(
        cohort => :full,
        other_cohort => :full,
        Group::AUTO_GROUPS[:moderators] => :full,
      )
      space.save!
      cohort.add(member)
      other_cohort.add(member)

      cohort.remove(member)

      expect(sidebar_ids(member)).to include(space.id)
    end
  end

  describe "adding a space to the setting" do
    it "puts it in the sidebar of everyone already in its group, and not of moderators" do
      SiteSetting.cardwell_cohort_space_categories = other_space.id.to_s
      cohort.add(member)
      moderator = Fabricate(:moderator)
      expect(sidebar_ids(member)).not_to include(space.id)

      SiteSetting.cardwell_cohort_space_categories = "#{other_space.id}|#{space.id}"

      expect(sidebar_ids(member)).to include(space.id)
      expect(sidebar_ids(moderator)).not_to include(space.id)
    end
  end

  describe "removing a space from the setting" do
    it "leaves sidebars as they are" do
      cohort.add(member)

      SiteSetting.cardwell_cohort_space_categories = other_space.id.to_s

      expect(sidebar_ids(member)).to include(space.id)
    end
  end

  describe "when the part is off" do
    before { SiteSetting.cardwell_cohort_space_sidebar_enabled = false }

    it "adds nothing on join" do
      cohort.add(member)

      expect(sidebar_ids(member)).not_to include(space.id)
    end

    it "removes nothing on leave" do
      SiteSetting.cardwell_cohort_space_sidebar_enabled = true
      cohort.add(member)
      SiteSetting.cardwell_cohort_space_sidebar_enabled = false

      cohort.remove(member)

      expect(sidebar_ids(member)).to include(space.id)
    end

    it "adds nothing when a space is added to the setting" do
      SiteSetting.cardwell_cohort_space_categories = ""
      cohort.add(member)

      SiteSetting.cardwell_cohort_space_categories = space.id.to_s

      expect(sidebar_ids(member)).not_to include(space.id)
    end
  end
end
