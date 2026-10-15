# frozen_string_literal: true

RSpec.describe CardwellCommunity::InitialsAvatarsController do
  let(:dir) { Dir.mktmpdir }

  before do
    allow(CardwellCommunity::InitialsAvatars).to receive(:cache_dir).and_return(dir)
    SiteSetting.login_required = true
  end

  after { FileUtils.rm_rf(dir) }

  # Email clients fetch avatars with no session, so the route has to answer
  # signed out even on a login-required site.
  it "serves an avatar signed out, cached for a day and without cookies" do
    Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield")

    get "/letter_avatar/cardwell/dana.whitfield/7ba0ec/48.png"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("image/png")
    expect(response.headers["Cache-Control"]).to include("max-age=86400", "public")
    expect(response.headers["Set-Cookie"]).to be_blank
  end

  it "answers a username with no account the same way" do
    get "/letter_avatar/cardwell/john.smith/7ba0ec/48.png"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("image/png")
  end

  it "leaves core's own letter avatar route alone" do
    get "/letter_avatar/dana/48/#{LetterAvatar.version}.png"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("image/png")
  end
end
