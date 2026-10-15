# frozen_string_literal: true

RSpec.describe CardwellCommunity::MessageNames do
  fab!(:dana) { Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield") }
  fab!(:pat) { Fabricate(:user, username: "pat.lee", name: "") }
  fab!(:viewer, :user)
  fab!(:open_group) { Fabricate(:group, name: "cohort-a", full_name: "Cohort A") }
  fab!(:hidden_group) do
    Fabricate(
      :group,
      name: "staff-only",
      full_name: "Staff only",
      visibility_level: Group.visibility_levels[:staff],
    )
  end

  let(:guardian) { Guardian.new(viewer) }

  describe ".names_for" do
    it "names people and groups the viewer can see" do
      names =
        described_class.names_for(
          [%w[user_left dana.whitfield], %w[removed_group cohort-a], %w[invited_user pat.lee]],
          guardian,
        )

      expect(names).to eq(
        %w[user_left dana.whitfield] => "Dana Whitfield",
        %w[removed_group cohort-a] => "Cohort A",
      )
    end

    it "leaves a group the viewer can't see on its handle" do
      expect(described_class.names_for([%w[removed_group staff-only]], guardian)).to eq({})
    end

    it "ignores notices that don't name anyone" do
      expect(described_class.names_for([%w[closed.enabled dana.whitfield]], guardian)).to eq({})
    end
  end

  describe "on a message" do
    fab!(:message) { Fabricate(:private_message_topic, user: viewer) }
    fab!(:first_post) { Fabricate(:post, topic: message, user: viewer) }
    fab!(:notice) { message.add_small_action(viewer, "user_left", "dana.whitfield") }

    def notice_json
      view = TopicView.new(message.id, viewer)
      serializer = TopicViewSerializer.new(view, scope: Guardian.new(viewer), root: false)
      serializer.as_json[:post_stream][:posts].find { |post| post[:id] == notice.id }
    end

    it "sends the name next to the handle, looked up for the page" do
      json = notice_json

      expect(json[:action_code_who]).to eq("dana.whitfield")
      expect(json[:action_code_who_name]).to eq("Dana Whitfield")
    end

    it "looks the name up for a post outside a TopicView" do
      json = PostSerializer.new(notice, scope: Guardian.new(viewer), root: false).as_json

      expect(json[:action_code_who_name]).to eq("Dana Whitfield")
    end

    # Activity rows have no TopicView, so their serializer takes this path.
    it "names one notice on its own, as activity rows do" do
      expect(described_class.name_for("user_left", "dana.whitfield", guardian)).to eq(
        "Dana Whitfield",
      )
      expect(described_class.name_for("invited_user", "pat.lee", guardian)).to be_nil
    end

    it "sends nothing when the site hides names" do
      SiteSetting.enable_names = false

      expect(notice_json).not_to have_key(:action_code_who_name)
    end

    it "sends nothing when the part is off" do
      SiteSetting.cardwell_message_names_enabled = false

      expect(notice_json).not_to have_key(:action_code_who_name)
    end
  end
end
