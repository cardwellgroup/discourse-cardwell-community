# frozen_string_literal: true

RSpec.describe "Message names: the composer's not-seen warning" do
  fab!(:viewer, :user)
  fab!(:away) do
    Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield", last_seen_at: 3.years.ago)
  end
  fab!(:away_nameless) do
    Fabricate(:user, username: "pat.lee", name: "", last_seen_at: 3.years.ago)
  end

  before { sign_in(viewer) }

  def warning
    get "/composer_messages/user_not_seen_in_a_while.json",
        params: {
          usernames: %w[dana.whitfield pat.lee],
        }
    expect(response.status).to eq(200)
    response.parsed_body
  end

  it "adds names next to the usernames, in the same order" do
    json = warning

    expect(json["usernames"]).to eq(%w[dana.whitfield pat.lee])
    expect(json["names"]).to eq(["Dana Whitfield", "pat.lee"])
  end

  it "leaves core's answer alone when the part is off" do
    SiteSetting.cardwell_message_names_enabled = false

    expect(warning).not_to have_key("names")
  end
end
