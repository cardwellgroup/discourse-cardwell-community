# frozen_string_literal: true

RSpec.describe CardwellCommunity::InitialsAvatarsController do
  let(:root) { Dir.mktmpdir }

  before do
    allow(CardwellCommunity::InitialsAvatars).to receive(:cache_root).and_return(root)
    SiteSetting.login_required = true
  end

  after { FileUtils.rm_rf(root) }

  # Email clients fetch avatars with no session, so the route has to answer
  # signed out even on a login-required site.
  it "serves an avatar signed out, cached for half a day each by nginx and browsers, without cookies" do
    Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield")

    get "/letter_avatar/cardwell/dana.whitfield/7ba0ec/48.png"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("image/png")
    expect(response.headers["Cache-Control"]).to include("max-age=43200", "public")
    expect(response.headers["X-Accel-Expires"]).to eq("43200")
    expect(response.headers["Set-Cookie"]).to be_blank
  end

  it "answers a username with no account the same way" do
    get "/letter_avatar/cardwell/john.smith/7ba0ec/48.png"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("image/png")
  end

  context "with rate limits on" do
    before { RateLimiter.enable }

    # Discourse's spec helpers replace RSpec's stub_const with a block form
    # (target, name, value) that restores the constant when the block ends.
    def with_one_draw_per_minute(&blk)
      stub_const(CardwellCommunity::InitialsAvatars, :STRANGER_DRAWS_PER_MINUTE, 1, &blk)
    end

    it "limits draws for usernames with no account" do
      with_one_draw_per_minute do
        get "/letter_avatar/cardwell/john.smith/7ba0ec/48.png"
        expect(response.status).to eq(200)

        get "/letter_avatar/cardwell/jane.doe/7ba0ec/48.png"
        expect(response.status).to eq(429)
      end
    end

    it "doesn't limit members" do
      Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield")
      Fabricate(:user, username: "pat.lee", name: "Pat Lee")

      with_one_draw_per_minute do
        get "/letter_avatar/cardwell/dana.whitfield/7ba0ec/48.png"
        expect(response.status).to eq(200)

        get "/letter_avatar/cardwell/pat.lee/7ba0ec/48.png"
        expect(response.status).to eq(200)
      end
    end
  end

  it "leaves core's own letter avatar route alone" do
    get "/letter_avatar/dana/48/#{LetterAvatar.version}.png"

    expect(response.status).to eq(200)
    expect(response.media_type).to eq("image/png")
  end
end
