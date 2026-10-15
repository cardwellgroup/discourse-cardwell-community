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

    it "keeps an accent stored as a separate mark" do
      expect(described_class.initials_from_name("Jose\u0301 A\u0301lvarez")).to eq("JÁ")
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

    # ImageMagick reads text starting with @ as a file name.
    it "draws a question mark for a username with no letter or digit" do
      expect(described_class.initials_for_username("@")).to eq("?")
      expect(described_class.initials_for_username("%")).to eq("?")
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
      expect(user.avatar_template).to include("/letter_avatar/cardwell/")

      user.update!(uploaded_avatar: Fabricate(:image_upload, user:))

      expect(user.avatar_template).to include("/user_avatar/")
    end
  end

  describe ".with_image" do
    let(:root) { Dir.mktmpdir }

    before { allow(described_class).to receive(:cache_root).and_return(root) }
    after { FileUtils.rm_rf(root) }

    def size_of(username, size)
      described_class.with_image(username, size) { |image| FastImage.size(image) }
    end

    it "draws a member's PNG at the requested size and keeps it" do
      Fabricate(:user, username: "dana.whitfield", name: "Dana Whitfield")

      first = described_class.with_image("dana.whitfield", 48) { |image| image }

      expect(FastImage.size(first)).to eq([48, 48])
      expect(first).to start_with(File.expand_path(root))
      expect(described_class.with_image("dana.whitfield", 48) { |image| image }).to eq(first)
    end

    it "draws a stranger's tile without keeping it" do
      kept = described_class.with_image("john.smith", 48) { |image| [image, FastImage.size(image)] }

      expect(kept.last).to eq([48, 48])
      expect(File.exist?(kept.first)).to eq(false)
      expect(Dir.glob(File.join(root, "**", "*.png"))).to be_empty
    end

    it "rounds the size up to one of the avatar sizes browsers ask for" do
      SiteSetting.avatar_sizes = "24|48|96"

      expect(size_of("x", 45)).to eq([48, 48])
      expect(size_of("x", 5_000)).to eq([96, 96])
    end

    it "clears tiles from older versions" do
      old = File.join(root, "0", "intervariable")
      FileUtils.mkdir_p(old)

      described_class.cleanup_old

      expect(Dir.exist?(old)).to eq(false)
    end
  end
end
