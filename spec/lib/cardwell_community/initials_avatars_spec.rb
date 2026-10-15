# frozen_string_literal: true

RSpec.describe CardwellCommunity::InitialsAvatars do
  describe ".initials_from_name" do
    it "takes the first letters of the first and last words" do
      expect(described_class.initials_from_name("Dana Whitfield")).to eq("DW")
      expect(described_class.initials_from_name("Mary-Kate O'Neil")).to eq("MO")
      expect(described_class.initials_from_name("José Álvarez")).to eq("JÁ")
    end

    it "gives one letter for a one-word name" do
      expect(described_class.initials_from_name("Dana")).to eq("D")
    end

    it "skips suffixes and anything after a comma" do
      expect(described_class.initials_from_name("John Smith Jr.")).to eq("JS")
      expect(described_class.initials_from_name("John Smith III")).to eq("JS")
      expect(described_class.initials_from_name("Jane Doe, CPA")).to eq("JD")
    end

    it "keeps a one-word name that looks like a suffix" do
      expect(described_class.initials_from_name("V")).to eq("V")
    end

    it "returns nil for a name with no letters" do
      expect(described_class.initials_from_name("  ")).to be_nil
      expect(described_class.initials_from_name(nil)).to be_nil
    end
  end

  describe ".initials_for_username" do
    fab!(:named) { Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield") }
    fab!(:nameless) { Fabricate(:user, username: "pat.lee", name: "") }

    it "uses the name when there is one" do
      expect(described_class.initials_for_username("Dana.Whitfield")).to eq("DW")
    end

    it "falls back to the username's first letter, core's rule, when the name is empty" do
      expect(described_class.initials_for_username("pat.lee")).to eq("P")
    end

    # A signed-out visitor can't tell a member from a guessed username.
    it "takes initials from the parts of a username with no account" do
      expect(described_class.initials_for_username("john.smith")).to eq("JS")
      expect(described_class.initials_for_username("john_q-smith")).to eq("JS")
    end
  end

  describe "the avatar template" do
    it "points letter avatars at the plugin's route" do
      template = User.system_avatar_template("Dana.Whitfield")
      color = User.letter_avatar_color("dana.whitfield")

      expect(template).to eq("/letter_avatar/cardwell/Dana.Whitfield/#{color}/{size}.png")
    end

    it "is core's again when the part is turned off" do
      SiteSetting.cardwell_initials_avatars_enabled = false

      expect(User.system_avatar_template("dana.whitfield")).not_to include("/cardwell/")
    end

    it "is core's again when the plugin is turned off" do
      # Turning the plugin off also makes part 0 publish on its channel, which
      # would outlive this example and break part 0's check of the boot value.
      allow(CardwellCommunity::CompileTimeout).to receive(:broadcast!)
      SiteSetting.cardwell_community_enabled = false

      expect(User.system_avatar_template("dana.whitfield")).not_to include("/cardwell/")
    end

    it "leaves uploaded photos alone" do
      user = Fabricate(:user, username: "with.photo")
      user.update!(uploaded_avatar: Fabricate(:image_upload, user:))

      expect(user.avatar_template).to include("/user_avatar/")
    end
  end

  describe ".image_for" do
    let(:dir) { Dir.mktmpdir }

    before { allow(described_class).to receive(:cache_dir).and_return(dir) }
    after { FileUtils.rm_rf(dir) }

    it "draws a PNG at the requested size and reuses it" do
      Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield")

      image = described_class.image_for("dana.whitfield", 48)

      expect(File.extname(image)).to eq(".png")
      expect(FastImage.size(image)).to eq([48, 48])
      expect(described_class.image_for("dana.whitfield", 48)).to eq(image)
    end

    it "keeps the size inside core's limits" do
      expect(FastImage.size(described_class.image_for("x", 5_000))).to eq([360, 360])
    end
  end
end
