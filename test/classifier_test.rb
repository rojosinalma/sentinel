# frozen_string_literal: true

require_relative "test_helper"

class ClassifierTest < Minitest::Test
  def view(opencode:, ssh: "down", icmp: "down", traefik: "down")
    Sentinel::HostView.new(name: "node-a", opencode: opencode, ssh: ssh, icmp: icmp,
                           traefik: traefik, probed_at: Time.now).freeze
  end

  def test_classify_ok
    assert_equal :ok, Sentinel::Classifier.classify(view(opencode: "up 2.0.25"), quorum: "up")
    assert_equal :ok, Sentinel::Classifier.classify(view(opencode: "up auth?"), quorum: "down")
  end

  def test_classify_isolated
    assert_equal :isolated, Sentinel::Classifier.classify(view(opencode: "down"), quorum: "down")
    assert_equal :isolated, Sentinel::Classifier.classify(view(opencode: "down"), quorum: "n/a")
  end

  def test_classify_degraded
    assert_equal :degraded, Sentinel::Classifier.classify(view(opencode: "down", ssh: "up"), quorum: "up")
    assert_equal :degraded, Sentinel::Classifier.classify(view(opencode: "down", icmp: "up"), quorum: "up")
  end

  def test_classify_dead
    assert_equal :dead, Sentinel::Classifier.classify(view(opencode: "down"), quorum: "up")
  end

  def test_agree_majority_dead
    assert_equal :dead, Sentinel::Classifier.agree({ "a" => :dead, "b" => :dead, "c" => :ok }, majority: 2)
    assert_equal :dead, Sentinel::Classifier.agree({ "a" => :dead, "b" => :dead }, majority: 2)
  end

  def test_agree_majority_down_but_not_dead
    assert_equal :degraded, Sentinel::Classifier.agree({ "a" => :dead, "b" => :degraded, "c" => :ok }, majority: 2)
    assert_equal :degraded, Sentinel::Classifier.agree({ "a" => :degraded, "b" => :degraded, "c" => :ok }, majority: 2)
  end

  def test_agree_no_majority
    assert_equal :ok, Sentinel::Classifier.agree({ "a" => :dead, "b" => :ok, "c" => :ok }, majority: 2)
    assert_equal :ok, Sentinel::Classifier.agree({ "a" => :dead, "b" => :ok }, majority: 2)
    assert_equal :ok, Sentinel::Classifier.agree({ "a" => :isolated, "b" => :ok, "c" => :ok }, majority: 2)
  end

  def test_agree_single_view
    assert_equal :ok, Sentinel::Classifier.agree({ "a" => :dead }, majority: 2)
  end
end
