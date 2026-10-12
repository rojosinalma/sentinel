# frozen_string_literal: true

require_relative "test_helper"

class ClassifierTest < Minitest::Test
  def view(ssh: "down", icmp: "down", traefik: "down")
    Sentinel::HostView.new(name: "node-a", ssh: ssh, icmp: icmp, traefik: traefik, probed_at: Time.now).freeze
  end

  def classify(state, quorum:, **probes) = Sentinel::Classifier.classify(state, view(**probes), quorum: quorum)

  def test_classify_ok
    assert_equal :ok, classify("up 2.0.25", quorum: "up")
    assert_equal :ok, classify("up auth?", quorum: "down")
  end

  def test_classify_isolated
    assert_equal :isolated, classify("down", quorum: "down")
    assert_equal :isolated, classify("down", quorum: "n/a")
    assert_equal :isolated, classify(nil, quorum: "down")
  end

  def test_classify_degraded
    assert_equal :degraded, classify("down", quorum: "up", ssh: "up")
    assert_equal :degraded, classify("down", quorum: "up", icmp: "up")
  end

  def test_classify_standby
    view = view(ssh: "up")
    assert_equal :standby, Sentinel::Classifier.classify("down", view, quorum: "up", standing_by: true)
    assert_equal :ok, Sentinel::Classifier.classify("up 2.0.25", view, quorum: "up", standing_by: true)
    assert_equal :isolated, Sentinel::Classifier.classify("down", view, quorum: "down", standing_by: true)
    assert_equal :dead, Sentinel::Classifier.classify("down", view(), quorum: "up", standing_by: true),
                 "a dark standby host is dead, whatever its role"
  end

  def test_classify_dead
    assert_equal :dead, classify("down", quorum: "up")
    assert_equal :dead, classify(nil, quorum: "up"), "a service the host does not report is down"
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
