#include "ns3/bridge-module.h"
#include "ns3/buildings-module.h"
#include "ns3/core-module.h"
#include "ns3/csma-module.h"
#include "ns3/error-model.h"
#include "ns3/mobility-module.h"
#include "ns3/network-module.h"
#include "ns3/propagation-module.h"
#include "ns3/random-variable-stream.h"
#include "ns3/tap-bridge-module.h"
#include "ns3/wifi-module.h"

#include "json.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <map>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace ns3;
using json = nlohmann::json;

namespace ns3
{

class UcsTapBridgeAdhocWifiMac : public AdhocWifiMac
{
public:
  static TypeId GetTypeId();
  void SetAddress(Mac48Address address) override;
  bool SupportsSendFrom() const override;
  void LockAddress(Mac48Address address);

private:
  void ApplyAddress(Mac48Address address);
  void Receive(Ptr<const WifiMpdu> mpdu, uint8_t linkId) override;

  bool m_addressLocked{false};
  Mac48Address m_lockedAddress;
};

NS_OBJECT_ENSURE_REGISTERED(UcsTapBridgeAdhocWifiMac);

TypeId
UcsTapBridgeAdhocWifiMac::GetTypeId()
{
  static TypeId tid = TypeId("ns3::UcsTapBridgeAdhocWifiMac")
                          .SetParent<AdhocWifiMac>()
                          .SetGroupName("Wifi")
                          .AddConstructor<UcsTapBridgeAdhocWifiMac>();
  return tid;
}

void
UcsTapBridgeAdhocWifiMac::SetAddress(Mac48Address address)
{
  if (m_addressLocked && address != m_lockedAddress)
  {
    ApplyAddress(m_lockedAddress);
    return;
  }
  ApplyAddress(address);
}

bool
UcsTapBridgeAdhocWifiMac::SupportsSendFrom() const
{
  return true;
}

void
UcsTapBridgeAdhocWifiMac::LockAddress(Mac48Address address)
{
  m_addressLocked = true;
  m_lockedAddress = address;
  ApplyAddress(address);
}

void
UcsTapBridgeAdhocWifiMac::ApplyAddress(Mac48Address address)
{
  AdhocWifiMac::SetAddress(address);
  for (uint8_t linkId : GetLinkIds())
  {
    Ptr<FrameExchangeManager> fem = GetFrameExchangeManager(linkId);
    if (fem != nullptr)
    {
      fem->SetAddress(address);
    }
  }
}

void
UcsTapBridgeAdhocWifiMac::Receive(Ptr<const WifiMpdu> mpdu, uint8_t linkId)
{
  const WifiMacHeader &hdr = mpdu->GetHeader();
  NS_ASSERT(!hdr.IsCtl());

  const Mac48Address from = hdr.GetAddr2();
  const Mac48Address to = hdr.GetAddr1();
  const Mac48Address self = Mac48Address::ConvertFrom(GetDevice()->GetAddress());

  if (hdr.IsData() && !to.IsGroup() && to != self)
  {
    return;
  }

  if (GetWifiRemoteStationManager()->IsBrandNew(from))
  {
    if (GetHtSupported(SINGLE_LINK_OP_ID))
    {
      GetWifiRemoteStationManager()->AddAllSupportedMcs(from);
      GetWifiRemoteStationManager()->AddStationHtCapabilities(
          from,
          GetHtCapabilities(SINGLE_LINK_OP_ID));
    }
    if (GetVhtSupported(SINGLE_LINK_OP_ID))
    {
      GetWifiRemoteStationManager()->AddStationVhtCapabilities(
          from,
          GetVhtCapabilities(SINGLE_LINK_OP_ID));
    }
    if (GetHeSupported())
    {
      GetWifiRemoteStationManager()->AddStationHeCapabilities(
          from,
          GetHeCapabilities(SINGLE_LINK_OP_ID));
    }
    if (GetEhtSupported())
    {
      GetWifiRemoteStationManager()->AddStationEhtCapabilities(
          from,
          GetEhtCapabilities(SINGLE_LINK_OP_ID));
    }
    GetWifiRemoteStationManager()->AddAllSupportedModes(from);
    GetWifiRemoteStationManager()->RecordDisassociated(from);
  }

  if (hdr.IsData())
  {
    if (hdr.IsQosData() && hdr.IsQosAmsdu())
    {
      DeaggregateAmsduAndForward(mpdu);
    }
    else
    {
      ForwardUp(mpdu->GetPacket(), from, to);
    }
    return;
  }

  WifiMac::Receive(mpdu, linkId);
}

} // namespace ns3

/*
 * UCS Fleet L2 Link Mesh Topology
 *
 * Purpose:
 *   - Keep IP routing and neighbor visibility in Linux/UAV namespaces.
 *   - Use ns-3 only as a link-layer wireless fabric.
 *   - Export one tap per external endpoint: GS plus each UAV eth1 access.
 *   - In Wi-Fi mode, treat links/mesh_links as endpoint metric pairs for
 *     MatrixPropagationLossModel updates, not independent forwarding pipes.
 *   - Do not install ns-3 InternetStack and do not populate ns-3 routes.
 *
 * If globals.experiment_net.impairment_policy is "ns3_pairwise_links", ns-3
 * runs a small learning L2 datapath instead of BridgeNetDevice. Each forwarded
 * frame is charged against the ingress/egress endpoint pair, so ARP, ping, and
 * application packets all see the same per-pair link model without ns-3 owning
 * IP routes.
 *
 * If globals.experiment_net.impairment_policy is "ns3_wifi_ad_hoc", ns-3 uses a
 * native ad-hoc Wi-Fi PHY/MAC as the link-layer fabric. The large/small fading
 * model updates a MatrixPropagationLossModel per endpoint pair, while ns-3 Wi-Fi
 * decides frame decode, contention, ACK/retry, collision, and final drop.
 *
 * "linux_pairwise_tc" is retained only for rollback/debug compatibility.
 *
 * CSMA and Wi-Fi endpoint TapBridge devices use UseBridge mode because Linux
 * attaches each UAV tap to a small access bridge with a veth peer. Native
 * AdhocWifiMac does not advertise SendFrom support, so UcsTapBridgeAdhocWifiMac
 * opts into SendFrom for this one-MAC-per-endpoint bridge shape and locks the
 * ns-3 Wi-Fi MAC to the Linux app-facing endpoint MAC. This preserves the
 * endpoint MAC visible to Linux while still letting ns-3 Wi-Fi own contention,
 * ACK/retry, decode, and final drop.
 *
 * Linux side is expected to install on-link /32 routes to peer UAV/GS
 * addresses so containers ARP for real peer endpoint IPs instead of ns-3
 * router gateway IPs.
 */

namespace
{

struct CliOptions
{
  std::string topologyFile{[] {
    const char *env = std::getenv("UCS_MESH_TOPOLOGY_FILE");
    if (env != nullptr && env[0] != '\0')
    {
      return std::string{env};
    }
    return std::string{"topology/wifi_adhoc_matrix_2x3_6uav.json"};
  }()};
  std::optional<bool> verboseOverride;
  std::optional<bool> pcapOverride;
  bool live{false};
};

struct GlobalConfig
{
  std::string scenarioId;
  std::string fabricMode{"l2_link_mesh"};

  std::string gsId;
  std::string tapLeft;
  std::string timeFile;

  std::string defaultDataRate{"1Gbps"};
  std::string defaultDelay{"2ms"};
  std::string defaultAccessDataRate{"1Gbps"};
  std::string defaultAccessDelay{"0ms"};
  std::string impairmentPolicy{"ns3_access_links"};
  std::string tick{"200ms"};

  bool pcap{false};
  bool verbose{true};
  double stopTime{0.0};
  Vector gsPose{0.0, 0.0, 0.0};

  bool DynamicAccessImpairment() const
  {
    return impairmentPolicy == "ns3_access_links";
  }

  bool Ns3PairwiseImpairment() const
  {
    return impairmentPolicy == "ns3_pairwise_links";
  }

  bool Ns3WifiAdhoc() const
  {
    return impairmentPolicy == "ns3_wifi_ad_hoc";
  }

  bool EndpointPairLinkImpairment() const
  {
    return Ns3PairwiseImpairment() || Ns3WifiAdhoc();
  }
};

struct InstanceSpec
{
  std::string id;
  std::string type; // ground_station / uav
  std::string tapName;
  std::string metricsFile;
  std::string endpointMacAddress;
  std::optional<uint32_t> endpointMacOrdinal;
  bool hasSpawnPose{false};
  Vector spawnPose{0.0, 0.0, 0.0};
};

struct LinkSpec
{
  std::string id;
  std::string src;
  std::string dst;
  bool enabled{true};

  std::string metricsFile;
  std::string dataRate;
  std::string baseDelay;

  double lossMin{0.0};
  double lossMax{0.30};
  double distNoLoss{50.0};
  double distMax{500.0};

  std::string jitterPerMps{"0.05ms"};
  std::string jitterMax{"10ms"};
};

struct BuildingObstacleSpec
{
  std::string id;
  Vector center{0.0, 0.0, 0.0};
  Vector size{1.0, 1.0, 1.0};
  std::string buildingType{"Commercial"};
  std::string extWallsType{"ConcreteWithWindows"};
  uint16_t floors{1};
};

struct LinkSimulationConfig
{
  bool enabled{false};
  std::string model{"distance_linear"};
  // These two ns-3 Buildings/3GPP fields are used only by the legacy
  // ns3_buildings_pathloss mode. large_small_fading_v1 instantiates
  // LogDistance directly and adds statistical geometry-aware impairment terms.
  std::string propagationLossModel{"ns3::ThreeGppUmiStreetCanyonPropagationLossModel"};
  std::string channelConditionModel{"ns3::BuildingsChannelConditionModel"};
  std::string pathLossModel{"ns3::LogDistancePropagationLossModel"};
  std::string multipathModel{"ns3::NakagamiPropagationLossModel"};
  std::string dopplerModel{"ns3::JakesPropagationLossModel"};
  double frequencyHz{2.4e9};
  bool shadowingEnabled{false};
  double pathLossExponent{3.0};
  double pathLossReferenceDistanceM{1.0};
  double pathLossReferenceLossDb{40.045997};
  bool pathLossReferenceLossDbExplicit{false};
  bool shadowFadingEnabled{true};
  double shadowFadingStddevDb{4.0};
  double shadowFadingCorrelationDistanceM{25.0};
  bool obstructionLossEnabled{false};
  double obstructionBaseLossDb{0.0};
  double obstructionLossPerHitDb{0.0};
  double obstructionLossPerMeterDb{2.0};
  double obstructionLossMaxDb{20.0};
  double obstructionMinIntersectionM{0.05};
  double obstructionDiffractionMarginM{0.0};
  double obstructionDiffractionLossDb{0.0};
  // Smoothly ramps the per-hit obstruction penalty over the first meters of
  // penetration. A value of 0 keeps the legacy step-at-min-intersection behavior.
  double obstructionEdgeRampM{0.0};
  double obstructionSmoothingTauS{0.0};
  bool multipathFadingEnabled{true};
  double multipathMinRelativeSpeedMps{0.1};
  double multipathCoherenceDistanceM{2.0};
  double multipathCoherenceTimeS{1.0};
  double multipathMaxLossDb{1000.0};
  double multipathMaxGainDb{1000.0};
  double multipathSmoothingTauS{0.0};
  double nakagamiDistance1M{80.0};
  double nakagamiDistance2M{200.0};
  double nakagamiM0{1.5};
  double nakagamiM1{0.75};
  double nakagamiM2{0.75};
  bool dopplerFadingEnabled{false};
  double dopplerMinRelativeSpeedMps{0.1};
  double jakesDopplerHz{80.0};
  uint32_t jakesOscillators{20};
  double txPowerDbm{20.0};
  double rxSensitivityDbm{-86.0};
  double rxLossFullDbm{-96.0};
  std::string linkErrorModel{"snr_packet_error_v1"};
  double noiseFloorDbm{-96.0};
  double packetErrorBytes{1200.0};
  double codingGainDb{0.0};
  std::string mcs{"qpsk_1_2"};
  double mcsSensitivity10PerDbm{std::numeric_limits<double>::quiet_NaN()};
  double implementationMarginDb{0.0};
  double blerTransitionDb{1.5};
  // Maximum packet error probability applied by RF-derived error models.
  // This is intentionally separate from LinkSpec::lossMax, which is also
  // used by the legacy distance-linear fallback model.
  double packetErrorRateCap{1.0};
  // First-order smoothing for the PHY packet error probability. This avoids
  // unrealistic cliff-like jumps when a UAV crosses an obstruction boundary.
  double packetErrorSmoothingTauS{0.0};
  bool packetSizeScalingEnabled{false};
  std::string phyModel{"receiver_sensitivity_bler_v1"};
  std::string phyAbstraction{"single_attempt_decode_model"};
  std::string macModel{"l2_arq_state_machine_v1"};
  std::string macMediumAccess{"shared_radio_serial_dcf_v1"};
  std::string macQueueModel{"bounded_per_link_pending_queue"};
  std::string macAckModel{"abstract_unicast_ack_no_independent_ack_phy"};
  std::string macDataRate{"20Mbps"};
  uint32_t macQueueLimitPackets{256};
  bool macAirtimeAccounting{true};
  bool macRetryEnabled{false};
  uint32_t macRetryMaxRetries{0};
  std::string macRetrySlotTime{"1ms"};
  std::string macRetryJitterMax{"0ms"};
  bool macRetryBroadcast{false};
  std::string wifiStandard{"802.11a"};
  std::string wifiRateManager{"ns3::ConstantRateWifiManager"};
  std::string wifiDataMode{"OfdmRate24Mbps"};
  std::string wifiControlMode{"OfdmRate6Mbps"};
  std::string wifiMacType{"ns3::AdhocWifiMac"};
  std::string wifiTapBridgeMode{"UseBridge"};
  std::string wifiChannelSettings{""};
  double wifiRxSensitivityDbm{std::numeric_limits<double>::quiet_NaN()};
  double wifiCcaEdThresholdDbm{-92.0};
  std::vector<BuildingObstacleSpec> obstacles;

  bool Ns3BuildingsPathloss() const
  {
    return enabled && model == "ns3_buildings_pathloss";
  }

  bool LargeSmallFading() const
  {
    return enabled && model == "large_small_fading_v1";
  }

  bool ReceiverSensitivityBler() const
  {
    return linkErrorModel == "receiver_sensitivity_bler_v1" ||
           linkErrorModel == "mcs_bler_v1";
  }

  double WifiRxSensitivityDbm() const
  {
    return std::isfinite(wifiRxSensitivityDbm) ? wifiRxSensitivityDbm : rxLossFullDbm;
  }
};

struct TopologyConfig
{
  GlobalConfig globals;
  LinkSimulationConfig linkSimulation;
  std::vector<InstanceSpec> instances;
  std::vector<LinkSpec> links;
  std::vector<LinkSpec> meshLinks;
};

struct LinkMetricsSample
{
  double speed{0.0};
  double dist{0.0};
  bool hasPositions{false};
  bool valid{true};
  bool modelSeen{true};
  Vector srcPosition{0.0, 0.0, 0.0};
  Vector dstPosition{0.0, 0.0, 0.0};
};

constexpr char kSharedMetricsMagic[8] = {'U', 'C', 'S', 'M', 'S', 'H', '0', '1'};
constexpr uint32_t kSharedMetricsVersion = 1;
constexpr size_t kSharedMetricsLinkIdBytes = 64;
constexpr char kLinkStateMagic[8] = {'U', 'C', 'S', 'L', 'N', 'K', '0', '1'};
constexpr uint32_t kLinkStateVersion = 1;
constexpr uint32_t kLinkStatePayloadBytes = 256U * 1024U;

#pragma pack(push, 1)
struct SharedMetricsHeader
{
  char magic[8];
  uint32_t version;
  uint32_t linkCount;
  uint64_t seq;
  double simTime;
};

struct SharedMetricsRecord
{
  char linkId[kSharedMetricsLinkIdBytes];
  double values[8];
  uint8_t valid;
  uint8_t modelSeen;
  uint8_t reserved[6];
};

struct LinkStateHeader
{
  char magic[8];
  uint32_t version;
  uint32_t payloadBytes;
  uint64_t seq;
  double simTime;
  double wallTime;
  uint32_t usedBytes;
  uint32_t lineCount;
  uint8_t reserved[16];
};
#pragma pack(pop)

static_assert(sizeof(SharedMetricsHeader) == 32, "unexpected shared metrics header size");
static_assert(sizeof(SharedMetricsRecord) == 136, "unexpected shared metrics record size");
static_assert(sizeof(LinkStateHeader) == 64, "unexpected link state header size");

struct SharedMetricsChannel
{
  std::string path;
  int fd{-1};
  const uint8_t *data{nullptr};
  size_t size{0};
  bool loggedOpen{false};
  bool snapshotValid{false};
  uint64_t seq{0};
  double simTime{0.0};
  std::map<std::string, LinkMetricsSample> samples;
};

struct LinkStateChannel
{
  std::string path;
  std::string historyPath;
  int fd{-1};
  uint8_t *data{nullptr};
  size_t size{0};
  bool loggedOpen{false};
  bool warningLogged{false};
  bool historyStarted{false};
  uint64_t seq{0};
  double lastHistoryWallTimeS{-1.0};
};

struct FadingRuntimeState
{
  bool shadowInitialized{false};
  double shadowDb{0.0};
  double pathLossDb{0.0};
  bool obstructionInitialized{false};
  double obstructionLossDb{0.0};
  double obstructionRawLossDb{0.0};
  std::string channelState{"UNKNOWN"};
  double obstructionLastUpdateS{0.0};
  double lastDistanceM{0.0};
  bool multipathInitialized{false};
  bool multipathResampled{false};
  double multipathDeltaDb{0.0};
  double multipathTargetDeltaDb{0.0};
  double multipathLastDistanceM{0.0};
  double multipathLastUpdateS{0.0};
  double multipathLastSmoothUpdateS{0.0};
  bool packetErrorRateInitialized{false};
  double packetErrorRate{0.0};
  double packetErrorRateLastUpdateS{0.0};
};

struct LinkRuntime
{
  LinkSpec spec;

  Ptr<Node> edgeNode;
  Ptr<NetDevice> edgeDevice;
  Ptr<NetDevice> coreSideDevice;
  Ptr<CsmaChannel> channel;
  Ptr<RateErrorModel> edgeRxErrorModel;
  Ptr<RateErrorModel> coreRxErrorModel;
  Ptr<TapBridge> tapBridge;
  Ptr<UniformRandomVariable> jitterRng;

  double lastSpeed{0.0};
  double lastDist{0.0};
  double currentLoss{0.0};
  double currentRawLoss{0.0};
  double currentPhyLoss{0.0};
  double currentRxPowerDbm{std::numeric_limits<double>::quiet_NaN()};
  bool currentLossFromPathloss{false};
  std::string currentLossModel{"distance_linear"};
  FadingRuntimeState fadingState;
  Time currentJitter{MilliSeconds(0)};
  Time currentBaseDelay{MilliSeconds(0)};
  Time currentRetryDelay{MilliSeconds(0)};
  Time currentDelay{MilliSeconds(0)};
};

struct PairLinkRuntime
{
  LinkSpec spec;
  Ptr<UniformRandomVariable> jitterRng;
  Ptr<UniformRandomVariable> errorRng;
  Ptr<UniformRandomVariable> retryJitterRng;
  Ptr<UniformRandomVariable> backoffRng;
  Ptr<RateErrorModel> packetErrorModel;

  double lastSpeed{0.0};
  double lastDist{0.0};
  double currentLoss{0.0};
  double currentRawLoss{0.0};
  double currentPhyLoss{0.0};
  double currentRxPowerDbm{std::numeric_limits<double>::quiet_NaN()};
  bool currentLossFromPathloss{false};
  std::string currentLossModel{"distance_linear"};
  FadingRuntimeState fadingState;
  Time currentJitter{MilliSeconds(0)};
  Time currentBaseDelay{MilliSeconds(0)};
  Time currentRetryDelay{MilliSeconds(0)};
  Time currentQueueDelay{MilliSeconds(0)};
  Time currentBusyDelay{MilliSeconds(0)};
  Time currentAirtime{MilliSeconds(0)};
  Time currentDelay{MilliSeconds(0)};
  double currentMacExpectedDrop{0.0};
  double currentMacDeliveryLoss{0.0};
  double currentMacRetryAvg{0.0};
  std::string currentMacDropReason{"none"};
  Time macBusyUntil{MilliSeconds(0)};
  uint32_t pendingMacFrames{0};
  uint64_t pendingMacBytes{0};

  uint64_t forwarded{0};
  uint64_t dropped{0};
  uint64_t macDelivered{0};
  uint64_t macDropped{0};
  uint64_t macDroppedRetryLimit{0};
  uint64_t macDroppedQueue{0};
  uint64_t macDroppedBroadcastNoRetry{0};
  uint64_t macPhyAttempts{0};
  uint64_t macRetryAttempts{0};
};

struct PhyAttemptResult
{
  bool decoded{false};
  double rxPowerDbm{std::numeric_limits<double>::quiet_NaN()};
  double rawPacketErrorRate{0.0};
  double phyPerSingleAttempt{0.0};
  std::string model{"distance_linear"};
  std::string failureReason{"none"};
  Time airtime{MilliSeconds(0)};
};

struct MacDeliveryResult
{
  bool delivered{false};
  uint32_t attempts{0};
  uint32_t retryCount{0};
  Time queueDelay{MilliSeconds(0)};
  Time busyDelay{MilliSeconds(0)};
  Time retryDelay{MilliSeconds(0)};
  Time airtime{MilliSeconds(0)};
  double firstAttemptPer{0.0};
  double lastAttemptPer{0.0};
  double lastRxPowerDbm{std::numeric_limits<double>::quiet_NaN()};
  uint32_t packetBytes{0};
  bool consumesPendingFrame{true};
  std::string dropReason{"none"};
};

struct WifiEndpointStats
{
  uint64_t macTxPackets{0};
  uint64_t macTxBytes{0};
  uint64_t macRxPackets{0};
  uint64_t macRxBytes{0};
  uint64_t macPromiscRxPackets{0};
  uint64_t macPromiscRxBytes{0};
  uint64_t macTxDropPackets{0};
  uint64_t macRxDropPackets{0};
  uint64_t phyTxBeginPackets{0};
  uint64_t phyTxBeginBytes{0};
  uint64_t phyTxEndPackets{0};
  uint64_t phyTxDropPackets{0};
  uint64_t phyRxBeginPackets{0};
  uint64_t phyRxBeginBytes{0};
  uint64_t phyRxEndPackets{0};
  uint64_t phyRxEndBytes{0};
  uint64_t phyRxDropPackets{0};
  uint64_t ackedMpdu{0};
  uint64_t nackedMpdu{0};
  uint64_t droppedMpdu{0};
  uint64_t finalDataFailed{0};
  uint64_t retryLimitDrops{0};
  uint64_t mpduResponseTimeouts{0};
  uint64_t retryCountTotal{0};
  std::string lastMacDropReason{"none"};
  uint32_t lastPhyRxDropReason{0};
  uint32_t lastResponseTimeoutReason{0};
};

struct CorePortRuntime
{
  std::string endpointId;
  Ptr<NetDevice> device;
};

struct TopologyRuntime
{
  TopologyConfig config;

  Ptr<Node> coreNode;
  Ptr<BridgeNetDevice> coreBridge;

  Ptr<Node> gsPortNode;
  Ptr<NetDevice> gsEdgeDevice;
  Ptr<NetDevice> gsCoreSideDevice;
  Ptr<CsmaChannel> gsIngressChannel;
  Ptr<TapBridge> gsTapBridge;

  NetDeviceContainer corePortDevices;

  std::map<std::string, InstanceSpec> instanceMap;
  std::map<std::string, Ptr<Node>> uavEdgeNodeMap;
  std::vector<LinkRuntime> dynamicLinks;
  std::vector<CorePortRuntime> corePorts;
  std::map<std::string, uint32_t> learnedMacToPort;
  std::map<std::string, std::size_t> pairLinkIndexByEndpointKey;
  std::vector<PairLinkRuntime> pairLinks;
  NodeContainer wifiNodes;
  NetDeviceContainer wifiDevices;
  Ptr<YansWifiChannel> wifiChannel;
  Ptr<MatrixPropagationLossModel> wifiLossModel;
  std::map<std::string, uint32_t> wifiEndpointIndex;
  std::map<std::string, Ptr<NetDevice>> wifiEndpointDevice;
  std::map<std::string, Ptr<TapBridge>> wifiTapBridge;
  std::map<std::string, WifiEndpointStats> wifiEndpointStats;
  double lastWifiStatsLogTimeS{-1.0};
  SharedMetricsChannel sharedMetrics;
  LinkStateChannel linkState;
  std::map<std::string, Ptr<ConstantPositionMobilityModel>> endpointMobility;
  std::map<std::string, Ptr<MobilityBuildingInfo>> endpointBuildingInfo;
  Ptr<ChannelConditionModel> channelConditionModel;
  Ptr<PropagationLossModel> propagationLossModel;
  Ptr<LogDistancePropagationLossModel> largeSmallPathLossModel;
  Ptr<NakagamiPropagationLossModel> largeSmallMultipathModel;
  Ptr<PropagationLossModel> largeSmallDopplerModel;
  Ptr<ConstantPositionMobilityModel> fadingSrcMobility;
  Ptr<ConstantPositionMobilityModel> fadingDstMobility;
  Ptr<NormalRandomVariable> shadowNormalRng;
  Time radioBusyUntil{MilliSeconds(0)};
  uint64_t radioTxAttempts{0};
  double radioAirtimeSeconds{0.0};

  bool pcapEnabled{false};
  bool verbose{true};

  bool ttyUi{false};
  bool uiInitialized{false};
  uint32_t uiRows{0};
};

[[noreturn]] static void
Fatal(const std::string &msg)
{
  NS_FATAL_ERROR("[ucs_fleet_l2_mesh_topology] " << msg);
}

static void
LogInfo(const std::string &msg, bool enabled = true)
{
  if (enabled)
  {
    std::cout << msg << std::endl;
  }
}

struct McsProfile
{
  std::string name;
  double modulationBitsPerSymbol{2.0};
  double codingRate{0.5};
  double sensitivity10PerDbm{-86.0};
  double transitionDb{1.5};
};

static std::optional<McsProfile>
LookupMcsProfile(const std::string &name)
{
  if (name == "bpsk_1_2")
  {
    return McsProfile{name, 1.0, 0.5, -90.0, 1.6};
  }
  if (name == "qpsk_1_2")
  {
    return McsProfile{name, 2.0, 0.5, -86.0, 1.5};
  }
  if (name == "qpsk_3_4")
  {
    return McsProfile{name, 2.0, 0.75, -84.5, 1.4};
  }
  if (name == "16qam_1_2")
  {
    return McsProfile{name, 4.0, 0.5, -82.0, 1.5};
  }
  if (name == "16qam_3_4")
  {
    return McsProfile{name, 4.0, 0.75, -78.5, 1.4};
  }
  if (name == "64qam_2_3")
  {
    return McsProfile{name, 6.0, 2.0 / 3.0, -74.5, 1.3};
  }
  if (name == "64qam_3_4")
  {
    return McsProfile{name, 6.0, 0.75, -73.0, 1.2};
  }
  return std::nullopt;
}

static McsProfile
ResolveMcsProfile(const LinkSimulationConfig &sim)
{
  auto profile = LookupMcsProfile(sim.mcs);
  if (!profile.has_value())
  {
    Fatal("unsupported globals.link_simulation.link_layer.mcs: " + sim.mcs);
  }
  profile->transitionDb = sim.blerTransitionDb;
  if (std::isfinite(sim.mcsSensitivity10PerDbm))
  {
    profile->sensitivity10PerDbm = sim.mcsSensitivity10PerDbm;
  }
  return *profile;
}

static WifiStandard
ResolveWifiStandard(const std::string &standard)
{
  if (standard == "802.11a" || standard == "WIFI_STANDARD_80211a")
  {
    return WIFI_STANDARD_80211a;
  }
  if (standard == "802.11b" || standard == "WIFI_STANDARD_80211b")
  {
    return WIFI_STANDARD_80211b;
  }
  if (standard == "802.11g" || standard == "WIFI_STANDARD_80211g")
  {
    return WIFI_STANDARD_80211g;
  }
  if (standard == "802.11p" || standard == "WIFI_STANDARD_80211p")
  {
    return WIFI_STANDARD_80211p;
  }
  if (standard == "802.11n" || standard == "WIFI_STANDARD_80211n")
  {
    return WIFI_STANDARD_80211n;
  }
  if (standard == "802.11ac" || standard == "WIFI_STANDARD_80211ac")
  {
    return WIFI_STANDARD_80211ac;
  }
  if (standard == "802.11ax" || standard == "WIFI_STANDARD_80211ax")
  {
    return WIFI_STANDARD_80211ax;
  }
  if (standard == "802.11be" || standard == "WIFI_STANDARD_80211be")
  {
    return WIFI_STANDARD_80211be;
  }

  Fatal("unsupported globals.link_simulation.wifi.standard: " + standard);
}

static std::string
ReadTextFile(const std::string &path)
{
  std::ifstream ifs(path);
  if (!ifs.good())
  {
    Fatal("failed to open file: " + path);
  }

  std::ostringstream oss;
  oss << ifs.rdbuf();
  return oss.str();
}

static const json &
RequireObjectField(const json &obj, const std::string &name)
{
  if (!obj.contains(name))
  {
    Fatal("missing required object field: " + name);
  }
  if (!obj.at(name).is_object())
  {
    Fatal("field is not an object: " + name);
  }
  return obj.at(name);
}

static const json &
RequireArrayField(const json &obj, const std::string &name)
{
  if (!obj.contains(name))
  {
    Fatal("missing required array field: " + name);
  }
  if (!obj.at(name).is_array())
  {
    Fatal("field is not an array: " + name);
  }
  return obj.at(name);
}

static std::string
RequireStringField(const json &obj, const std::string &name)
{
  if (!obj.contains(name))
  {
    Fatal("missing required string field: " + name);
  }
  if (!obj.at(name).is_string())
  {
    Fatal("field is not a string: " + name);
  }
  return obj.at(name).get<std::string>();
}

static std::string
OptionalStringField(const json &obj, const std::string &name, const std::string &fallback)
{
  if (!obj.contains(name))
  {
    return fallback;
  }
  if (!obj.at(name).is_string())
  {
    Fatal("field is not a string: " + name);
  }
  return obj.at(name).get<std::string>();
}

static bool
OptionalBoolField(const json &obj, const std::string &name, bool fallback)
{
  if (!obj.contains(name))
  {
    return fallback;
  }

  const auto &v = obj.at(name);
  if (v.is_boolean())
  {
    return v.get<bool>();
  }
  if (v.is_number_integer())
  {
    const auto n = v.get<int>();
    if (n == 0)
    {
      return false;
    }
    if (n == 1)
    {
      return true;
    }
  }

  Fatal("field is not a boolean (or 0/1 integer): " + name);
  return fallback;
}

static double
OptionalNumberField(const json &obj, const std::string &name, double fallback)
{
  if (!obj.contains(name))
  {
    return fallback;
  }
  if (!obj.at(name).is_number())
  {
    Fatal("field is not a number: " + name);
  }
  return obj.at(name).get<double>();
}

static double
FriisFreeSpacePathLossDb(double frequencyHz, double distanceM)
{
  constexpr double speedOfLightMps = 299792458.0;
  constexpr double pi = 3.14159265358979323846;
  const double wavelengthM = speedOfLightMps / frequencyHz;
  const double ratio = 4.0 * pi * distanceM / wavelengthM;
  return 20.0 * std::log10(ratio);
}

static bool
EndsWith(const std::string &s, const std::string &suffix)
{
  if (suffix.size() > s.size())
  {
    return false;
  }
  return s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

static std::string
Trim(const std::string &s)
{
  std::size_t i = 0;
  while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i])))
  {
    ++i;
  }

  std::size_t j = s.size();
  while (j > i && std::isspace(static_cast<unsigned char>(s[j - 1])))
  {
    --j;
  }

  return s.substr(i, j - i);
}

static double
ParseDoublePrefix(const std::string &value, const std::string &suffix)
{
  const std::string trimmed = Trim(value);
  if (!EndsWith(trimmed, suffix))
  {
    throw std::runtime_error("suffix mismatch");
  }

  const std::string numberPart = Trim(trimmed.substr(0, trimmed.size() - suffix.size()));
  return std::stod(numberPart);
}

static std::optional<bool>
ParseBoolOverrideString(const std::string &raw)
{
  if (raw.empty())
  {
    return std::nullopt;
  }
  if (raw == "1" || raw == "true" || raw == "TRUE")
  {
    return true;
  }
  if (raw == "0" || raw == "false" || raw == "FALSE")
  {
    return false;
  }
  Fatal("invalid boolean override value: " + raw);
  return std::nullopt;
}

static CliOptions ParseCli(int argc, char **argv);
static TopologyConfig LoadTopologyConfig(const CliOptions &cli);
static LinkSimulationConfig ParseLinkSimulationConfig(const json &globals);
static LinkSpec ParseLinkSpec(const json &lnk, const TopologyConfig &cfg,
                              const std::string &sectionName);
static void ValidateTopologyConfig(const TopologyConfig &cfg);
static std::string DeriveEndpointMacAddress(const InstanceSpec &spec,
                                            const GlobalConfig &globals,
                                            std::size_t instanceIndex);
static std::string NormalizeMacAddress(const std::string &mac);
static bool IsValidMacAddress(const std::string &mac);
static bool IsSafeIdentifier(const std::string &value);
static void RequireSafeIdentifier(const std::string &value,
                                  const std::string &context);
static void RequireTimeString(const std::string &value,
                              const std::string &context,
                              bool strictlyPositive);
static void RequireDataRateString(const std::string &value,
                                  const std::string &context);

static const InstanceSpec &FindGroundStation(const TopologyConfig &cfg);
static std::vector<InstanceSpec> GetUavInstances(const TopologyConfig &cfg);
static std::vector<LinkSpec> GetEnabledGsUavLinks(const TopologyConfig &cfg);
static std::vector<LinkSpec> GetEnabledPairwiseLinks(const TopologyConfig &cfg);

static TopologyRuntime BuildTopology(const TopologyConfig &cfg);
static void SetupBuildingsPathloss(TopologyRuntime &rt);
static void SetupLargeSmallFading(TopologyRuntime &rt);
static void CreateCoreBridge(TopologyRuntime &rt);
static void CreateGsIngress(TopologyRuntime &rt);
static void CreateUavAccessLinks(TopologyRuntime &rt);
static void CreateWifiAdhocFabric(TopologyRuntime &rt);
static void SetWifiEndpointMacAddress(const Ptr<NetDevice> &device,
                                      const InstanceSpec &inst);
static void RegisterWifiTraceSinks(TopologyRuntime &rt,
                                   const std::string &endpointId,
                                   const Ptr<NetDevice> &device);
static void RegisterCorePort(TopologyRuntime &rt, const std::string &endpointId,
                             const Ptr<NetDevice> &device);
static void BuildPairwiseLinks(TopologyRuntime &rt);
static void InstallPairwiseSwitch(TopologyRuntime &rt);
static void EnablePcapIfNeeded(TopologyRuntime &rt);

static std::optional<Time> ParseTimeStrictValue(const std::string &value);
static Time ParseTimeOrDefault(const std::string &value, const Time &fallback);
static DataRate ParseDataRateOrDefault(const std::string &value,
                                       const std::string &fallback);
static std::optional<double> ReadSharedTime(const std::string &timeFile);
static std::optional<LinkMetricsSample> ReadLinkMetrics(const std::string &metricsFile);
static std::string SharedMetricsPath(const TopologyConfig &cfg);
static bool RefreshSharedMetricsSnapshot(TopologyRuntime &rt);
static std::optional<LinkMetricsSample> ReadLinkMetrics(TopologyRuntime &rt,
                                                        const LinkSpec &spec);
static void CleanupSharedMetrics(TopologyRuntime &rt);

static Vector RequireVector3Array(const json &obj, const std::string &name,
                                  const std::string &context);
static Vector OptionalVectorObjectField(const json &obj, const std::string &name,
                                        const Vector &fallback);
static Building::BuildingType_t ParseBuildingType(const std::string &value);
static Building::ExtWallsType_t ParseExtWallsType(const std::string &value);
static Ptr<ChannelConditionModel> CreateChannelConditionModel(const std::string &typeName);
static Ptr<PropagationLossModel> CreatePropagationLossModel(const std::string &typeName);
static double ComputeLargeSmallFadingRxPower(TopologyRuntime &rt, FadingRuntimeState &state,
                                             const LinkMetricsSample &sample);
static double ComputeWifiMatrixRxPower(TopologyRuntime &rt, FadingRuntimeState &state,
                                       const LinkSpec &spec,
                                       const LinkMetricsSample &sample);
static Vector EndpointFallbackPosition(const TopologyConfig &cfg,
                                       const std::string &endpointId);
static double Distance3d(const Vector &a, const Vector &b);
static double UpdateShadowFadingDb(TopologyRuntime &rt, FadingRuntimeState &state,
                                   double distanceM, double relativeSpeedMps);
static double UpdateMultipathFadingDeltaDb(TopologyRuntime &rt, FadingRuntimeState &state,
                                           double baseRxPowerDbm, double distanceM,
                                           double relativeSpeedMps);
static void UpdateEndpointPosition(TopologyRuntime &rt, const std::string &endpointId,
                                   const Vector &position);
static double ComputePacketErrorRateFromRxPower(const LinkSimulationConfig &sim,
                                                const LinkSpec &spec,
                                                double rxPowerDbm,
                                                double &rawPacketErrorRate);
static double UpdatePacketErrorRateSmoothing(const LinkSimulationConfig &sim,
                                             FadingRuntimeState &state,
                                             double packetErrorRate);
static double ComputeLinkLoss(TopologyRuntime &rt, const LinkSpec &spec,
                              const LinkMetricsSample &sample,
                              FadingRuntimeState &state,
                              double &rxPowerDbm, bool &fromPathloss,
                              std::string &lossModel,
                              double &rawPacketErrorRate);
// Legacy receiver-sensitivity/pairwise MAC approximation. Not authoritative
// under ns3_wifi_ad_hoc.
static double ComputePostMacDropProbability(const LinkSimulationConfig &sim,
                                            double phyPacketErrorRate,
                                            bool groupOrBroadcast);
static Time ComputeExpectedMacRetryDelay(const LinkSimulationConfig &sim,
                                         double phyPacketErrorRate,
                                         bool groupOrBroadcast);
static double ScalePacketErrorRateForPacketSize(const LinkSimulationConfig &sim,
                                                double referencePacketErrorRate,
                                                uint32_t packetBytes);
static Time ComputeMacFrameAirtime(const LinkSimulationConfig &sim,
                                   const LinkSpec &spec,
                                   uint32_t packetBytes);
static bool UseSharedRadioMedium(const LinkSimulationConfig &sim);
static PhyAttemptResult ComputePairwisePhyAttempt(TopologyRuntime &rt,
                                                  PairLinkRuntime &pl,
                                                  uint32_t packetBytes);
static std::string AddressKey(const Address &address);
static std::string EndpointPairKey(const std::string &a, const std::string &b);
static bool IsGroupOrBroadcast(const Address &address);
static double ComputeLoss(const LinkSpec &spec, double dist);
static Time ComputeJitterAmplitude(const LinkSpec &spec, double speed);
static Time ComputeDelay(const LinkSpec &spec, const Time &jitterAmplitude,
                         const Ptr<UniformRandomVariable> &rng, Time &appliedJitter);

static void ApplyLinkState(LinkRuntime &rt, double loss, const Time &appliedJitter, const Time &delay);
static void UpdatePairwiseLinks(TopologyRuntime &rt);
static void UpdateWifiAdhocLinks(TopologyRuntime &rt);
static bool CorePromiscReceive(Ptr<NetDevice> device, Ptr<const Packet> packet,
                               uint16_t protocol, const Address &src,
                               const Address &dst, NetDevice::PacketType packetType);
static void SendPairwiseFrame(Ptr<NetDevice> outDevice, Ptr<Packet> packet,
                              Address src, Address dst, uint16_t protocol);
// Legacy ns3_pairwise_links path only. ns3_wifi_ad_hoc delegates MAC retry,
// contention, and final drop to native ns-3 Wi-Fi.
static void EnqueuePairwiseMacFrame(TopologyRuntime &rt, std::size_t pairIndex,
                                    uint32_t egressPort, Ptr<Packet> packet,
                                    uint16_t protocol, Address src, Address dst,
                                    bool groupOrBroadcast);
static void ProcessPairwiseMacAttempt(TopologyRuntime *rt, std::size_t pairIndex,
                                      uint32_t egressPort, Ptr<Packet> packet,
                                      uint16_t protocol, Address src, Address dst,
                                      bool groupOrBroadcast, uint32_t attempt,
                                      Time enqueueTime, bool firstAttemptStarted,
                                      Time queueDelay, Time busyDelay,
                                      Time retryDelay, Time airtime,
                                      double firstAttemptPer);
static void CompletePairwiseMacDelivery(TopologyRuntime &rt, PairLinkRuntime &pl,
                                        const MacDeliveryResult &result);
static void ForwardPairwiseFrame(TopologyRuntime &rt, uint32_t ingressPort,
                                 Ptr<const Packet> packet, uint16_t protocol,
                                 const Address &src, const Address &dst);
static void LogTopologySummary(const TopologyRuntime &rt);
static void LogLinkInit(const LinkRuntime &rt, bool verbose);
static std::string LinkStateLine(double t, const LinkRuntime &rt);
static void LogLinkState(double t, const LinkRuntime &rt, bool verbose);
static void LogPairLinkInit(const PairLinkRuntime &rt, bool verbose);
static std::string PairLinkStateLine(double t, const PairLinkRuntime &rt);
static void LogPairLinkState(double t, const PairLinkRuntime &rt, bool verbose);
static std::string WifiEndpointStatsLine(double t, const std::string &endpointId,
                                         const WifiEndpointStats &stats);
static void LogWifiEndpointStats(TopologyRuntime &rt, double t);
static void WriteLinkStateSharedSnapshot(TopologyRuntime &rt, double t);
static void CleanupLinkStateChannel(TopologyRuntime &rt);

static void RenderStatusPanel(TopologyRuntime &rt, double t);
static void CleanupUi(TopologyRuntime &rt);

static void OnPeriodicUpdate(TopologyRuntime *rt);
static void SchedulePeriodicUpdates(TopologyRuntime &rt);

static TopologyRuntime *g_runtime = nullptr;

} // namespace

int
main(int argc, char **argv)
{
  GlobalValue::Bind("SimulatorImplementationType", StringValue("ns3::RealtimeSimulatorImpl"));
  GlobalValue::Bind("ChecksumEnabled", BooleanValue(true));

  CliOptions cli = ParseCli(argc, argv);
  TopologyConfig cfg = LoadTopologyConfig(cli);
  ValidateTopologyConfig(cfg);

  TopologyRuntime runtime = BuildTopology(cfg);
  LogTopologySummary(runtime);

  if (runtime.config.globals.DynamicAccessImpairment())
  {
    for (const auto &lr : runtime.dynamicLinks)
    {
      LogLinkInit(lr, runtime.verbose);
    }
  }
  for (const auto &pl : runtime.pairLinks)
  {
    LogPairLinkInit(pl, runtime.verbose);
  }

  if (!cli.live)
  {
    LogInfo("[run] live=0 (build-only check; exiting after topology construction)",
            runtime.verbose);
    return 0;
  }

  LogInfo("[run] live=1 (starting periodic update loop)", runtime.verbose);

  g_runtime = new TopologyRuntime(std::move(runtime));
  g_runtime->ttyUi = (::isatty(STDOUT_FILENO) != 0);

  Simulator::ScheduleNow(&OnPeriodicUpdate, g_runtime);

  if (g_runtime->config.globals.stopTime > 0.0)
  {
    Simulator::Stop(Seconds(g_runtime->config.globals.stopTime));
  }

  Simulator::Run();
  Simulator::Destroy();

  CleanupLinkStateChannel(*g_runtime);
  CleanupSharedMetrics(*g_runtime);
  CleanupUi(*g_runtime);
  delete g_runtime;
  g_runtime = nullptr;
  return 0;
}

namespace
{

CliOptions
ParseCli(int argc, char **argv)
{
  CliOptions cli;
  std::string verboseOverride;
  std::string pcapOverride;
  std::string liveOverride;

  CommandLine cmd(__FILE__);
  cmd.AddValue("topologyFile", "Path to topology JSON file", cli.topologyFile);
  cmd.AddValue("verboseOverride", "Optional override: 0/1 or true/false", verboseOverride);
  cmd.AddValue("pcapOverride", "Optional override: 0/1 or true/false", pcapOverride);
  cmd.AddValue("live", "0/1 or true/false; default 0", liveOverride);
  cmd.Parse(argc, argv);

  cli.verboseOverride = ParseBoolOverrideString(verboseOverride);
  cli.pcapOverride = ParseBoolOverrideString(pcapOverride);

  const auto liveParsed = ParseBoolOverrideString(liveOverride);
  if (liveParsed.has_value())
  {
    cli.live = *liveParsed;
  }

  return cli;
}

TopologyConfig
LoadTopologyConfig(const CliOptions &cli)
{
  TopologyConfig cfg;

  const std::string raw = ReadTextFile(cli.topologyFile);

  json root;
  try
  {
    root = json::parse(raw);
  }
  catch (const std::exception &e)
  {
    Fatal(std::string("failed to parse topology json: ") + e.what());
  }

  if (!root.is_object())
  {
    Fatal("topology root must be an object");
  }

  cfg.globals.scenarioId = OptionalStringField(root, "scenario_id", "");

  const json &globals = RequireObjectField(root, "globals");
  cfg.globals.fabricMode = OptionalStringField(globals, "fabric_mode", "l2_link_mesh");
  cfg.globals.gsId = RequireStringField(globals, "gs_id");
  cfg.globals.tapLeft = RequireStringField(globals, "tap_left");
  cfg.globals.timeFile = RequireStringField(globals, "time_file");
  cfg.globals.defaultDataRate = OptionalStringField(globals, "default_data_rate", "1Gbps");
  cfg.globals.defaultDelay = OptionalStringField(globals, "default_delay", "2ms");
  cfg.globals.defaultAccessDataRate =
      OptionalStringField(globals, "default_access_data_rate", "1Gbps");
  cfg.globals.defaultAccessDelay =
      OptionalStringField(globals, "default_access_delay", "0ms");
  cfg.globals.tick = OptionalStringField(globals, "tick", "200ms");
  cfg.globals.pcap = OptionalBoolField(globals, "pcap", false);
  cfg.globals.verbose = OptionalBoolField(globals, "verbose", true);
  cfg.globals.stopTime = OptionalNumberField(globals, "stop_time", 0.0);
  cfg.globals.gsPose = OptionalVectorObjectField(globals, "gs_pose", Vector(0.0, 0.0, 0.0));
  cfg.linkSimulation = ParseLinkSimulationConfig(globals);

  if (globals.contains("experiment_net"))
  {
    if (!globals.at("experiment_net").is_object())
    {
      Fatal("globals.experiment_net must be an object if present");
    }
    cfg.globals.impairmentPolicy =
        OptionalStringField(globals.at("experiment_net"), "impairment_policy",
                            cfg.globals.impairmentPolicy);
  }

  if (cli.verboseOverride.has_value())
  {
    cfg.globals.verbose = *cli.verboseOverride;
  }
  if (cli.pcapOverride.has_value())
  {
    cfg.globals.pcap = *cli.pcapOverride;
  }

  const json &instances = RequireArrayField(root, "instances");
  cfg.instances.reserve(instances.size());
  for (const auto &inst : instances)
  {
    if (!inst.is_object())
    {
      Fatal("instances[] element must be an object");
    }

    InstanceSpec spec;
    spec.id = RequireStringField(inst, "id");
    spec.type = RequireStringField(inst, "type");
    spec.tapName = OptionalStringField(inst, "tap_name", "");
    spec.metricsFile = OptionalStringField(inst, "metrics_file", "");
    if (inst.contains("idx"))
    {
      if (!inst.at("idx").is_number_integer())
      {
        Fatal("instances[].idx must be an integer when present: " + spec.id);
      }
      const int64_t idx = inst.at("idx").get<int64_t>();
      if (idx < 0 || idx > 65535)
      {
        Fatal("instances[].idx must fit uint16 for endpoint MAC derivation: " +
              spec.id);
      }
      spec.endpointMacOrdinal = static_cast<uint32_t>(idx);
    }
    spec.endpointMacAddress = OptionalStringField(inst, "mac_addr", "");
    if (spec.endpointMacAddress.empty())
    {
      spec.endpointMacAddress = OptionalStringField(inst, "endpoint_mac", "");
    }
    if (spec.endpointMacAddress.empty())
    {
      spec.endpointMacAddress =
          DeriveEndpointMacAddress(spec, cfg.globals, cfg.instances.size());
    }
    spec.endpointMacAddress = NormalizeMacAddress(spec.endpointMacAddress);
    if (!IsValidMacAddress(spec.endpointMacAddress))
    {
      Fatal("invalid endpoint MAC for instance " + spec.id + ": " +
            spec.endpointMacAddress);
    }
    if (inst.contains("spawn_pose"))
    {
      spec.spawnPose =
          OptionalVectorObjectField(inst, "spawn_pose", Vector(0.0, 0.0, 0.0));
      spec.hasSpawnPose = true;
    }
    cfg.instances.push_back(spec);
  }

  const json &links = RequireArrayField(root, "links");
  cfg.links.reserve(links.size());
  for (const auto &lnk : links)
  {
    cfg.links.push_back(ParseLinkSpec(lnk, cfg, "links"));
  }

  if (root.contains("mesh_links"))
  {
    if (!root.at("mesh_links").is_array())
    {
      Fatal("mesh_links must be an array if present");
    }

    const json &meshLinks = root.at("mesh_links");
    cfg.meshLinks.reserve(meshLinks.size());
    for (const auto &lnk : meshLinks)
    {
      cfg.meshLinks.push_back(ParseLinkSpec(lnk, cfg, "mesh_links"));
    }
  }

  return cfg;
}

LinkSimulationConfig
ParseLinkSimulationConfig(const json &globals)
{
  LinkSimulationConfig sim;
  if (!globals.contains("link_simulation"))
  {
    return sim;
  }

  const json &obj = globals.at("link_simulation");
  if (!obj.is_object())
  {
    Fatal("globals.link_simulation must be an object if present");
  }

  sim.enabled = OptionalBoolField(obj, "enabled", false);
  sim.model = OptionalStringField(obj, "model", sim.model);
  sim.propagationLossModel =
      OptionalStringField(obj, "propagation_loss_model", sim.propagationLossModel);
  sim.channelConditionModel =
      OptionalStringField(obj, "channel_condition_model", sim.channelConditionModel);
  sim.pathLossModel = OptionalStringField(obj, "path_loss_model", sim.pathLossModel);
  sim.multipathModel = OptionalStringField(obj, "multipath_model", sim.multipathModel);
  sim.dopplerModel = OptionalStringField(obj, "doppler_model", sim.dopplerModel);
  sim.frequencyHz = OptionalNumberField(obj, "frequency_hz", sim.frequencyHz);
  sim.shadowingEnabled = OptionalBoolField(obj, "shadowing_enabled", sim.shadowingEnabled);
  sim.pathLossExponent = OptionalNumberField(obj, "path_loss_exponent", sim.pathLossExponent);
  sim.pathLossReferenceDistanceM =
      OptionalNumberField(obj, "path_loss_reference_distance_m",
                          sim.pathLossReferenceDistanceM);
  if (obj.contains("path_loss_reference_loss_db"))
  {
    sim.pathLossReferenceLossDb =
        OptionalNumberField(obj, "path_loss_reference_loss_db", sim.pathLossReferenceLossDb);
    sim.pathLossReferenceLossDbExplicit = true;
  }
  sim.shadowFadingEnabled =
      OptionalBoolField(obj, "shadow_fading_enabled", sim.shadowFadingEnabled);
  sim.shadowFadingStddevDb =
      OptionalNumberField(obj, "shadow_fading_stddev_db", sim.shadowFadingStddevDb);
  sim.shadowFadingCorrelationDistanceM =
      OptionalNumberField(obj, "shadow_fading_correlation_distance_m",
                          sim.shadowFadingCorrelationDistanceM);
  sim.obstructionLossEnabled =
      OptionalBoolField(obj, "obstruction_loss_enabled", sim.obstructionLossEnabled);
  sim.obstructionBaseLossDb =
      OptionalNumberField(obj, "obstruction_base_loss_db",
                          sim.obstructionBaseLossDb);
  sim.obstructionLossPerHitDb =
      OptionalNumberField(obj, "obstruction_loss_per_hit_db",
                          sim.obstructionLossPerHitDb);
  sim.obstructionLossPerMeterDb =
      OptionalNumberField(obj, "obstruction_loss_per_meter_db",
                          sim.obstructionLossPerMeterDb);
  sim.obstructionLossMaxDb =
      OptionalNumberField(obj, "obstruction_loss_max_db", sim.obstructionLossMaxDb);
  sim.obstructionMinIntersectionM =
      OptionalNumberField(obj, "obstruction_min_intersection_m",
                          sim.obstructionMinIntersectionM);
  sim.obstructionDiffractionMarginM =
      OptionalNumberField(obj, "obstruction_diffraction_margin_m",
                          sim.obstructionDiffractionMarginM);
  sim.obstructionDiffractionLossDb =
      OptionalNumberField(obj, "obstruction_diffraction_loss_db",
                          sim.obstructionDiffractionLossDb);
  sim.obstructionEdgeRampM =
      OptionalNumberField(obj, "obstruction_edge_ramp_m",
                          sim.obstructionEdgeRampM);
  sim.obstructionSmoothingTauS =
      OptionalNumberField(obj, "obstruction_smoothing_tau_s",
                          sim.obstructionSmoothingTauS);
  sim.multipathFadingEnabled =
      OptionalBoolField(obj, "multipath_fading_enabled", sim.multipathFadingEnabled);
  sim.multipathMinRelativeSpeedMps =
      OptionalNumberField(obj, "multipath_min_relative_speed_mps",
                          sim.multipathMinRelativeSpeedMps);
  sim.multipathCoherenceDistanceM =
      OptionalNumberField(obj, "multipath_coherence_distance_m",
                          sim.multipathCoherenceDistanceM);
  sim.multipathCoherenceTimeS =
      OptionalNumberField(obj, "multipath_coherence_time_s",
                          sim.multipathCoherenceTimeS);
  sim.multipathMaxLossDb =
      OptionalNumberField(obj, "multipath_max_loss_db", sim.multipathMaxLossDb);
  sim.multipathMaxGainDb =
      OptionalNumberField(obj, "multipath_max_gain_db", sim.multipathMaxGainDb);
  sim.multipathSmoothingTauS =
      OptionalNumberField(obj, "multipath_smoothing_tau_s",
                          sim.multipathSmoothingTauS);
  sim.nakagamiDistance1M =
      OptionalNumberField(obj, "nakagami_distance1_m", sim.nakagamiDistance1M);
  sim.nakagamiDistance2M =
      OptionalNumberField(obj, "nakagami_distance2_m", sim.nakagamiDistance2M);
  sim.nakagamiM0 = OptionalNumberField(obj, "nakagami_m0", sim.nakagamiM0);
  sim.nakagamiM1 = OptionalNumberField(obj, "nakagami_m1", sim.nakagamiM1);
  sim.nakagamiM2 = OptionalNumberField(obj, "nakagami_m2", sim.nakagamiM2);
  sim.dopplerFadingEnabled =
      OptionalBoolField(obj, "doppler_fading_enabled", sim.dopplerFadingEnabled);
  sim.dopplerMinRelativeSpeedMps =
      OptionalNumberField(obj, "doppler_min_relative_speed_mps",
                          sim.dopplerMinRelativeSpeedMps);
  sim.jakesDopplerHz = OptionalNumberField(obj, "jakes_doppler_hz", sim.jakesDopplerHz);
  sim.txPowerDbm = OptionalNumberField(obj, "tx_power_dbm", sim.txPowerDbm);
  sim.rxSensitivityDbm = OptionalNumberField(obj, "rx_sensitivity_dbm", sim.rxSensitivityDbm);
  sim.rxLossFullDbm = OptionalNumberField(obj, "rx_loss_full_dbm", sim.rxLossFullDbm);
  sim.linkErrorModel = OptionalStringField(obj, "link_error_model", sim.linkErrorModel);
  sim.noiseFloorDbm = OptionalNumberField(obj, "noise_floor_dbm", sim.noiseFloorDbm);
  sim.packetErrorBytes = OptionalNumberField(obj, "packet_error_bytes", sim.packetErrorBytes);
  sim.codingGainDb = OptionalNumberField(obj, "coding_gain_db", sim.codingGainDb);
  sim.mcs = OptionalStringField(obj, "mcs", sim.mcs);
  sim.mcsSensitivity10PerDbm =
      OptionalNumberField(obj, "mcs_per10_sensitivity_dbm",
                          sim.mcsSensitivity10PerDbm);
  sim.implementationMarginDb =
      OptionalNumberField(obj, "implementation_margin_db", sim.implementationMarginDb);
  sim.blerTransitionDb =
      OptionalNumberField(obj, "bler_transition_db", sim.blerTransitionDb);
  sim.packetErrorRateCap =
      OptionalNumberField(obj, "packet_error_rate_cap", sim.packetErrorRateCap);
  sim.packetErrorRateCap =
      OptionalNumberField(obj, "packet_error_cap", sim.packetErrorRateCap);
  sim.packetErrorRateCap =
      OptionalNumberField(obj, "per_cap", sim.packetErrorRateCap);
  sim.packetErrorSmoothingTauS =
      OptionalNumberField(obj, "packet_error_smoothing_tau_s",
                          sim.packetErrorSmoothingTauS);
  sim.packetErrorSmoothingTauS =
      OptionalNumberField(obj, "per_smoothing_tau_s",
                          sim.packetErrorSmoothingTauS);
  sim.packetSizeScalingEnabled =
      OptionalBoolField(obj, "packet_size_scaling_enabled",
                        sim.packetSizeScalingEnabled);
  sim.phyModel = OptionalStringField(obj, "phy_model", sim.phyModel);
  sim.phyAbstraction =
      OptionalStringField(obj, "phy_abstraction", sim.phyAbstraction);
  sim.macModel = OptionalStringField(obj, "mac_model", sim.macModel);
  sim.macMediumAccess =
      OptionalStringField(obj, "mac_medium_access", sim.macMediumAccess);
  sim.macDataRate = OptionalStringField(obj, "mac_data_rate", sim.macDataRate);
  const double flatQueueLimitRaw =
      OptionalNumberField(obj, "mac_queue_limit_packets",
                          static_cast<double>(sim.macQueueLimitPackets));
  if (flatQueueLimitRaw < 0.0 || flatQueueLimitRaw > 100000.0 ||
      !std::isfinite(flatQueueLimitRaw))
  {
    Fatal("globals.link_simulation.mac_queue_limit_packets must be in [0, 100000]");
  }
  sim.macQueueLimitPackets = static_cast<uint32_t>(std::llround(flatQueueLimitRaw));
  sim.macAirtimeAccounting =
      OptionalBoolField(obj, "mac_airtime_accounting", sim.macAirtimeAccounting);
  sim.macRetryEnabled =
      OptionalBoolField(obj, "mac_retry_enabled", sim.macRetryEnabled);
  const double flatMacRetriesRaw =
      OptionalNumberField(obj, "mac_retry_max_retries",
                          static_cast<double>(sim.macRetryMaxRetries));
  if (flatMacRetriesRaw < 0.0 || flatMacRetriesRaw > 32.0 ||
      !std::isfinite(flatMacRetriesRaw))
  {
    Fatal("globals.link_simulation.mac_retry_max_retries must be in [0, 32]");
  }
  sim.macRetryMaxRetries = static_cast<uint32_t>(std::llround(flatMacRetriesRaw));
  sim.macRetrySlotTime =
      OptionalStringField(obj, "mac_retry_slot_time", sim.macRetrySlotTime);
  sim.macRetryJitterMax =
      OptionalStringField(obj, "mac_retry_jitter_max", sim.macRetryJitterMax);
  sim.macRetryBroadcast =
      OptionalBoolField(obj, "mac_retry_broadcast", sim.macRetryBroadcast);

  const double jakesOscillatorsRaw =
      OptionalNumberField(obj, "jakes_oscillators",
                          static_cast<double>(sim.jakesOscillators));
  if (jakesOscillatorsRaw < 4.0 || jakesOscillatorsRaw > 1000.0)
  {
    Fatal("globals.link_simulation.jakes_oscillators must be in [4, 1000]");
  }
  sim.jakesOscillators = static_cast<uint32_t>(std::llround(jakesOscillatorsRaw));

  if (obj.contains("large_scale"))
  {
    const json &largeScale = obj.at("large_scale");
    if (!largeScale.is_object())
    {
      Fatal("globals.link_simulation.large_scale must be an object if present");
    }

    if (largeScale.contains("path_loss"))
    {
      const json &pathLoss = largeScale.at("path_loss");
      if (!pathLoss.is_object())
      {
        Fatal("globals.link_simulation.large_scale.path_loss must be an object");
      }
      sim.pathLossModel = OptionalStringField(pathLoss, "model", sim.pathLossModel);
      sim.pathLossExponent =
          OptionalNumberField(pathLoss, "exponent", sim.pathLossExponent);
      sim.pathLossReferenceDistanceM =
          OptionalNumberField(pathLoss, "reference_distance_m",
                              sim.pathLossReferenceDistanceM);
      if (pathLoss.contains("reference_loss_db"))
      {
        sim.pathLossReferenceLossDb =
            OptionalNumberField(pathLoss, "reference_loss_db", sim.pathLossReferenceLossDb);
        sim.pathLossReferenceLossDbExplicit = true;
      }
    }

    if (largeScale.contains("shadow_fading"))
    {
      const json &shadow = largeScale.at("shadow_fading");
      if (!shadow.is_object())
      {
        Fatal("globals.link_simulation.large_scale.shadow_fading must be an object");
      }
      sim.shadowFadingEnabled =
          OptionalBoolField(shadow, "enabled", sim.shadowFadingEnabled);
      sim.shadowFadingStddevDb =
          OptionalNumberField(shadow, "stddev_db", sim.shadowFadingStddevDb);
      sim.shadowFadingCorrelationDistanceM =
          OptionalNumberField(shadow, "correlation_distance_m",
                              sim.shadowFadingCorrelationDistanceM);
    }
    if (largeScale.contains("obstruction"))
    {
      const json &obstruction = largeScale.at("obstruction");
      if (!obstruction.is_object())
      {
        Fatal("globals.link_simulation.large_scale.obstruction must be an object");
      }
      sim.obstructionLossEnabled =
          OptionalBoolField(obstruction, "enabled", sim.obstructionLossEnabled);
      sim.obstructionBaseLossDb =
          OptionalNumberField(obstruction, "base_loss_db",
                              sim.obstructionBaseLossDb);
      sim.obstructionLossPerHitDb =
          OptionalNumberField(obstruction, "loss_per_hit_db",
                              sim.obstructionLossPerHitDb);
      sim.obstructionLossPerMeterDb =
          OptionalNumberField(obstruction, "loss_per_meter_db",
                              sim.obstructionLossPerMeterDb);
      sim.obstructionLossMaxDb =
          OptionalNumberField(obstruction, "max_loss_db", sim.obstructionLossMaxDb);
      sim.obstructionMinIntersectionM =
          OptionalNumberField(obstruction, "min_intersection_m",
                              sim.obstructionMinIntersectionM);
      sim.obstructionDiffractionMarginM =
          OptionalNumberField(obstruction, "diffraction_margin_m",
                              sim.obstructionDiffractionMarginM);
      sim.obstructionDiffractionLossDb =
          OptionalNumberField(obstruction, "diffraction_loss_db",
                              sim.obstructionDiffractionLossDb);
      sim.obstructionEdgeRampM =
          OptionalNumberField(obstruction, "edge_ramp_m",
                              sim.obstructionEdgeRampM);
      sim.obstructionEdgeRampM =
          OptionalNumberField(obstruction, "transition_ramp_m",
                              sim.obstructionEdgeRampM);
      sim.obstructionSmoothingTauS =
          OptionalNumberField(obstruction, "smoothing_tau_s",
                              sim.obstructionSmoothingTauS);
    }
  }

  if (obj.contains("small_scale"))
  {
    const json &smallScale = obj.at("small_scale");
    if (!smallScale.is_object())
    {
      Fatal("globals.link_simulation.small_scale must be an object if present");
    }

    if (smallScale.contains("multipath"))
    {
      const json &multipath = smallScale.at("multipath");
      if (!multipath.is_object())
      {
        Fatal("globals.link_simulation.small_scale.multipath must be an object");
      }
      sim.multipathFadingEnabled =
          OptionalBoolField(multipath, "enabled", sim.multipathFadingEnabled);
      sim.multipathModel =
          OptionalStringField(multipath, "model", sim.multipathModel);
      sim.multipathMinRelativeSpeedMps =
          OptionalNumberField(multipath, "min_relative_speed_mps",
                              sim.multipathMinRelativeSpeedMps);
      sim.multipathCoherenceDistanceM =
          OptionalNumberField(multipath, "coherence_distance_m",
                              sim.multipathCoherenceDistanceM);
      sim.multipathCoherenceTimeS =
          OptionalNumberField(multipath, "coherence_time_s",
                              sim.multipathCoherenceTimeS);
      sim.multipathMaxLossDb =
          OptionalNumberField(multipath, "max_loss_db", sim.multipathMaxLossDb);
      sim.multipathMaxGainDb =
          OptionalNumberField(multipath, "max_gain_db", sim.multipathMaxGainDb);
      sim.multipathSmoothingTauS =
          OptionalNumberField(multipath, "smoothing_tau_s",
                              sim.multipathSmoothingTauS);
      sim.nakagamiDistance1M =
          OptionalNumberField(multipath, "distance1_m", sim.nakagamiDistance1M);
      sim.nakagamiDistance2M =
          OptionalNumberField(multipath, "distance2_m", sim.nakagamiDistance2M);
      sim.nakagamiM0 = OptionalNumberField(multipath, "m0", sim.nakagamiM0);
      sim.nakagamiM1 = OptionalNumberField(multipath, "m1", sim.nakagamiM1);
      sim.nakagamiM2 = OptionalNumberField(multipath, "m2", sim.nakagamiM2);
    }

    if (smallScale.contains("doppler"))
    {
      const json &doppler = smallScale.at("doppler");
      if (!doppler.is_object())
      {
        Fatal("globals.link_simulation.small_scale.doppler must be an object");
      }
      sim.dopplerFadingEnabled =
          OptionalBoolField(doppler, "enabled", sim.dopplerFadingEnabled);
      sim.dopplerModel = OptionalStringField(doppler, "model", sim.dopplerModel);
      sim.dopplerMinRelativeSpeedMps =
          OptionalNumberField(doppler, "min_relative_speed_mps",
                              sim.dopplerMinRelativeSpeedMps);
      sim.jakesDopplerHz =
          OptionalNumberField(doppler, "doppler_frequency_hz", sim.jakesDopplerHz);
      const double nestedOscillatorsRaw =
          OptionalNumberField(doppler, "oscillators",
                              static_cast<double>(sim.jakesOscillators));
      if (nestedOscillatorsRaw < 4.0 || nestedOscillatorsRaw > 1000.0)
      {
        Fatal("globals.link_simulation.small_scale.doppler.oscillators must be in [4, 1000]");
      }
      sim.jakesOscillators = static_cast<uint32_t>(std::llround(nestedOscillatorsRaw));
    }
  }

  if (obj.contains("link_layer"))
  {
    const json &linkLayer = obj.at("link_layer");
    if (!linkLayer.is_object())
    {
      Fatal("globals.link_simulation.link_layer must be an object");
    }
    sim.linkErrorModel =
        OptionalStringField(linkLayer, "error_model", sim.linkErrorModel);
    sim.noiseFloorDbm =
        OptionalNumberField(linkLayer, "noise_floor_dbm", sim.noiseFloorDbm);
    sim.packetErrorBytes =
        OptionalNumberField(linkLayer, "packet_error_bytes", sim.packetErrorBytes);
    sim.codingGainDb =
        OptionalNumberField(linkLayer, "coding_gain_db", sim.codingGainDb);
    sim.mcs = OptionalStringField(linkLayer, "mcs", sim.mcs);
    sim.mcsSensitivity10PerDbm =
        OptionalNumberField(linkLayer, "mcs_per10_sensitivity_dbm",
                            sim.mcsSensitivity10PerDbm);
    sim.implementationMarginDb =
        OptionalNumberField(linkLayer, "implementation_margin_db",
                            sim.implementationMarginDb);
    sim.blerTransitionDb =
        OptionalNumberField(linkLayer, "bler_transition_db", sim.blerTransitionDb);
    sim.packetErrorRateCap =
        OptionalNumberField(linkLayer, "per_cap", sim.packetErrorRateCap);
    sim.packetErrorRateCap =
        OptionalNumberField(linkLayer, "packet_error_rate_cap",
                            sim.packetErrorRateCap);
    sim.packetErrorRateCap =
        OptionalNumberField(linkLayer, "packet_error_cap",
                            sim.packetErrorRateCap);
    sim.packetErrorSmoothingTauS =
        OptionalNumberField(linkLayer, "per_smoothing_tau_s",
                            sim.packetErrorSmoothingTauS);
    sim.packetErrorSmoothingTauS =
        OptionalNumberField(linkLayer, "packet_error_smoothing_tau_s",
                            sim.packetErrorSmoothingTauS);
    sim.packetSizeScalingEnabled =
        OptionalBoolField(linkLayer, "packet_size_scaling",
                          sim.packetSizeScalingEnabled);
    sim.packetSizeScalingEnabled =
        OptionalBoolField(linkLayer, "packet_size_scaling_enabled",
                          sim.packetSizeScalingEnabled);

    if (linkLayer.contains("mac_retry"))
    {
      const json &macRetry = linkLayer.at("mac_retry");
      if (!macRetry.is_object())
      {
        Fatal("globals.link_simulation.link_layer.mac_retry must be an object");
      }
      sim.macRetryEnabled =
          OptionalBoolField(macRetry, "enabled", sim.macRetryEnabled);
      const double nestedMacRetriesRaw =
          OptionalNumberField(macRetry, "max_retries",
                              static_cast<double>(sim.macRetryMaxRetries));
      if (nestedMacRetriesRaw < 0.0 || nestedMacRetriesRaw > 32.0 ||
          !std::isfinite(nestedMacRetriesRaw))
      {
        Fatal("globals.link_simulation.link_layer.mac_retry.max_retries must be in [0, 32]");
      }
      sim.macRetryMaxRetries =
          static_cast<uint32_t>(std::llround(nestedMacRetriesRaw));
      sim.macRetrySlotTime =
          OptionalStringField(macRetry, "retry_slot_time", sim.macRetrySlotTime);
      sim.macRetrySlotTime =
          OptionalStringField(macRetry, "slot_time", sim.macRetrySlotTime);
      sim.macRetryJitterMax =
          OptionalStringField(macRetry, "retry_jitter_max", sim.macRetryJitterMax);
      sim.macRetryJitterMax =
          OptionalStringField(macRetry, "jitter_max", sim.macRetryJitterMax);
      sim.macRetryBroadcast =
          OptionalBoolField(macRetry, "broadcast_retries", sim.macRetryBroadcast);
    }
  }

  if (obj.contains("phy"))
  {
    const json &phy = obj.at("phy");
    if (!phy.is_object())
    {
      Fatal("globals.link_simulation.phy must be an object");
    }
    sim.phyModel = OptionalStringField(phy, "model", sim.phyModel);
    sim.linkErrorModel = sim.phyModel;
    sim.phyAbstraction =
        OptionalStringField(phy, "abstraction", sim.phyAbstraction);
    sim.noiseFloorDbm =
        OptionalNumberField(phy, "noise_floor_dbm", sim.noiseFloorDbm);
    sim.packetErrorBytes =
        OptionalNumberField(phy, "packet_error_bytes", sim.packetErrorBytes);
    sim.codingGainDb =
        OptionalNumberField(phy, "coding_gain_db", sim.codingGainDb);
    sim.mcs = OptionalStringField(phy, "mcs", sim.mcs);
    sim.mcsSensitivity10PerDbm =
        OptionalNumberField(phy, "mcs_per10_sensitivity_dbm",
                            sim.mcsSensitivity10PerDbm);
    sim.implementationMarginDb =
        OptionalNumberField(phy, "implementation_margin_db",
                            sim.implementationMarginDb);
    sim.blerTransitionDb =
        OptionalNumberField(phy, "bler_transition_db", sim.blerTransitionDb);
    sim.packetErrorRateCap =
        OptionalNumberField(phy, "per_cap", sim.packetErrorRateCap);
    sim.packetErrorRateCap =
        OptionalNumberField(phy, "packet_error_rate_cap",
                            sim.packetErrorRateCap);
    sim.packetErrorSmoothingTauS =
        OptionalNumberField(phy, "per_smoothing_tau_s",
                            sim.packetErrorSmoothingTauS);
    sim.packetErrorSmoothingTauS =
        OptionalNumberField(phy, "packet_error_smoothing_tau_s",
                            sim.packetErrorSmoothingTauS);
    sim.packetSizeScalingEnabled =
        OptionalBoolField(phy, "packet_size_scaling",
                          sim.packetSizeScalingEnabled);
    sim.packetSizeScalingEnabled =
        OptionalBoolField(phy, "packet_size_scaling_enabled",
                          sim.packetSizeScalingEnabled);
  }

  if (obj.contains("mac"))
  {
    const json &mac = obj.at("mac");
    if (!mac.is_object())
    {
      Fatal("globals.link_simulation.mac must be an object");
    }
    sim.macModel = OptionalStringField(mac, "model", sim.macModel);
    sim.macMediumAccess =
        OptionalStringField(mac, "medium_access", sim.macMediumAccess);
    sim.macQueueModel =
        OptionalStringField(mac, "queue_model", sim.macQueueModel);
    sim.macAckModel =
        OptionalStringField(mac, "ack_model", sim.macAckModel);
    sim.macDataRate = OptionalStringField(mac, "data_rate", sim.macDataRate);
    sim.macAirtimeAccounting =
        OptionalBoolField(mac, "airtime_accounting", sim.macAirtimeAccounting);
    sim.macRetryEnabled =
        OptionalBoolField(mac, "unicast_ack", sim.macRetryEnabled);
    sim.macRetryEnabled =
        OptionalBoolField(mac, "retry_enabled", sim.macRetryEnabled);
    const double retryLimitRaw =
        OptionalNumberField(mac, "retry_limit",
                            static_cast<double>(sim.macRetryMaxRetries));
    if (retryLimitRaw < 0.0 || retryLimitRaw > 32.0 ||
        !std::isfinite(retryLimitRaw))
    {
      Fatal("globals.link_simulation.mac.retry_limit must be in [0, 32]");
    }
    sim.macRetryMaxRetries = static_cast<uint32_t>(std::llround(retryLimitRaw));
    const double queueLimitRaw =
        OptionalNumberField(mac, "queue_limit_packets",
                            static_cast<double>(sim.macQueueLimitPackets));
    if (queueLimitRaw < 0.0 || queueLimitRaw > 100000.0 ||
        !std::isfinite(queueLimitRaw))
    {
      Fatal("globals.link_simulation.mac.queue_limit_packets must be in [0, 100000]");
    }
    sim.macQueueLimitPackets = static_cast<uint32_t>(std::llround(queueLimitRaw));
    sim.macRetrySlotTime =
        OptionalStringField(mac, "retry_slot_time", sim.macRetrySlotTime);
    sim.macRetrySlotTime =
        OptionalStringField(mac, "slot_time", sim.macRetrySlotTime);
    sim.macRetryJitterMax =
        OptionalStringField(mac, "retry_jitter_max", sim.macRetryJitterMax);
    sim.macRetryJitterMax =
        OptionalStringField(mac, "jitter_max", sim.macRetryJitterMax);
    sim.macRetryBroadcast =
        OptionalBoolField(mac, "broadcast_retries", sim.macRetryBroadcast);
  }

  if (obj.contains("wifi"))
  {
    const json &wifi = obj.at("wifi");
    if (!wifi.is_object())
    {
      Fatal("globals.link_simulation.wifi must be an object");
    }
    sim.wifiStandard = OptionalStringField(wifi, "standard", sim.wifiStandard);
    sim.wifiRateManager =
        OptionalStringField(wifi, "rate_manager", sim.wifiRateManager);
    sim.wifiDataMode = OptionalStringField(wifi, "data_mode", sim.wifiDataMode);
    sim.wifiControlMode =
        OptionalStringField(wifi, "control_mode", sim.wifiControlMode);
    sim.wifiMacType = OptionalStringField(wifi, "mac", sim.wifiMacType);
    sim.wifiTapBridgeMode =
        OptionalStringField(wifi, "tap_bridge_mode", sim.wifiTapBridgeMode);
    sim.wifiChannelSettings =
        OptionalStringField(wifi, "channel_settings", sim.wifiChannelSettings);
    sim.wifiRxSensitivityDbm =
        OptionalNumberField(wifi, "rx_sensitivity_dbm",
                            sim.wifiRxSensitivityDbm);
    sim.wifiCcaEdThresholdDbm =
        OptionalNumberField(wifi, "cca_ed_threshold_dbm",
                            sim.wifiCcaEdThresholdDbm);
  }

  if (sim.LargeSmallFading() && !sim.pathLossReferenceLossDbExplicit)
  {
    sim.pathLossReferenceLossDb = FriisFreeSpacePathLossDb(sim.frequencyHz, 1.0);
  }

  if (obj.contains("obstacles"))
  {
    if (!obj.at("obstacles").is_array())
    {
      Fatal("globals.link_simulation.obstacles must be an array if present");
    }

    const json &obstacles = obj.at("obstacles");
    sim.obstacles.reserve(obstacles.size());
    for (const auto &item : obstacles)
    {
      if (!item.is_object())
      {
        Fatal("globals.link_simulation.obstacles[] element must be an object");
      }

      BuildingObstacleSpec spec;
      spec.id = OptionalStringField(item, "id", "");
      spec.center = RequireVector3Array(item, "center", "globals.link_simulation.obstacles[]");
      spec.size = RequireVector3Array(item, "size", "globals.link_simulation.obstacles[]");
      spec.buildingType = OptionalStringField(item, "building_type", spec.buildingType);
      spec.extWallsType = OptionalStringField(item, "ext_walls_type", spec.extWallsType);

      const double floorsRaw = OptionalNumberField(item, "floors", spec.floors);
      if (floorsRaw < 1.0)
      {
        Fatal("globals.link_simulation.obstacles[].floors must be >= 1");
      }
      spec.floors = static_cast<uint16_t>(std::llround(floorsRaw));

      if (spec.size.x <= 0.0 || spec.size.y <= 0.0 || spec.size.z <= 0.0)
      {
        Fatal("globals.link_simulation.obstacles[].size values must be > 0");
      }

      sim.obstacles.push_back(spec);
    }
  }

  return sim;
}

LinkSpec
ParseLinkSpec(const json &lnk, const TopologyConfig &cfg, const std::string &sectionName)
{
  if (!lnk.is_object())
  {
    Fatal(sectionName + "[] element must be an object");
  }

  LinkSpec spec;
  spec.id = RequireStringField(lnk, "id");
  spec.src = RequireStringField(lnk, "src");
  spec.dst = RequireStringField(lnk, "dst");
  spec.enabled = OptionalBoolField(lnk, "enabled", true);

  spec.metricsFile = OptionalStringField(lnk, "metrics_file", "");
  spec.dataRate = OptionalStringField(lnk, "data_rate", cfg.globals.defaultDataRate);
  spec.baseDelay = OptionalStringField(lnk, "base_delay", cfg.globals.defaultDelay);

  spec.lossMin = OptionalNumberField(lnk, "loss_min", 0.0);
  spec.lossMax = OptionalNumberField(lnk, "loss_max", 0.30);
  spec.distNoLoss = OptionalNumberField(lnk, "dist_no_loss", 50.0);
  spec.distMax = OptionalNumberField(lnk, "dist_max", 500.0);

  spec.jitterPerMps = OptionalStringField(lnk, "jitter_per_mps", "0.05ms");
  spec.jitterMax = OptionalStringField(lnk, "jitter_max", "10ms");

  return spec;
}

std::string
NormalizeMacAddress(const std::string &mac)
{
  std::string normalized;
  normalized.reserve(mac.size());
  for (unsigned char ch : mac)
  {
    normalized.push_back(static_cast<char>(std::tolower(ch)));
  }
  return normalized;
}

bool
IsValidMacAddress(const std::string &mac)
{
  if (mac.size() != 17)
  {
    return false;
  }
  for (std::size_t i = 0; i < mac.size(); ++i)
  {
    if ((i + 1) % 3 == 0)
    {
      if (mac[i] != ':')
      {
        return false;
      }
      continue;
    }
    if (!std::isxdigit(static_cast<unsigned char>(mac[i])))
    {
      return false;
    }
  }
  const auto firstOctet = static_cast<unsigned int>(std::stoul(mac.substr(0, 2), nullptr, 16));
  if ((firstOctet & 0x01u) != 0)
  {
    return false;
  }
  if (mac == "00:00:00:00:00:00" || mac == "ff:ff:ff:ff:ff:ff")
  {
    return false;
  }
  return true;
}

bool
IsSafeIdentifier(const std::string &value)
{
  if (value.empty())
  {
    return false;
  }
  for (unsigned char ch : value)
  {
    if (std::isalnum(ch) || ch == '_' || ch == '-' || ch == '.' || ch == ':')
    {
      continue;
    }
    return false;
  }
  return true;
}

void
RequireSafeIdentifier(const std::string &value, const std::string &context)
{
  if (!IsSafeIdentifier(value))
  {
    Fatal(context + " must match [A-Za-z0-9_.:-]+: " + value);
  }
}

void
RequireTimeString(const std::string &value,
                  const std::string &context,
                  bool strictlyPositive)
{
  const auto parsed = ParseTimeStrictValue(value);
  if (!parsed.has_value())
  {
    Fatal(context + " must be a valid non-negative ns/us/ms/s time: " + value);
  }
  const int64_t ns = parsed->GetNanoSeconds();
  if (strictlyPositive && ns <= 0)
  {
    Fatal(context + " must be > 0: " + value);
  }
}

void
RequireDataRateString(const std::string &value, const std::string &context)
{
  try
  {
    const std::string trimmed = Trim(value);
    if (trimmed.empty())
    {
      Fatal(context + " must not be empty");
    }
    const DataRate dataRate(trimmed);
    if (dataRate.GetBitRate() == 0)
    {
      Fatal(context + " must be > 0: " + value);
    }
  }
  catch (const std::exception &e)
  {
    Fatal(context + " must be a valid ns-3 DataRate string: " + value +
          " (" + e.what() + ")");
  }
}

static std::optional<uint32_t>
ParseTrailingDecimalNumber(const std::string &value)
{
  std::size_t pos = value.size();
  while (pos > 0 && std::isdigit(static_cast<unsigned char>(value[pos - 1])))
  {
    --pos;
  }
  if (pos == value.size())
  {
    return std::nullopt;
  }
  try
  {
    return static_cast<uint32_t>(std::stoul(value.substr(pos)));
  }
  catch (const std::exception &)
  {
    return std::nullopt;
  }
}

static std::string
FormatDerivedEndpointMac(uint32_t ordinal)
{
  ordinal &= 0xffffu;
  std::ostringstream oss;
  oss << std::hex << std::setfill('0') << std::nouppercase;
  oss << "02:75:63:00:" << std::setw(2) << ((ordinal >> 8) & 0xffu)
      << ":" << std::setw(2) << (ordinal & 0xffu);
  return oss.str();
}

std::string
DeriveEndpointMacAddress(const InstanceSpec &spec,
                         const GlobalConfig &globals,
                         std::size_t instanceIndex)
{
  if (spec.id == globals.gsId || spec.type == "ground_station")
  {
    return FormatDerivedEndpointMac(0);
  }

  if (spec.endpointMacOrdinal.has_value())
  {
    return FormatDerivedEndpointMac(*spec.endpointMacOrdinal);
  }

  if (const auto ordinal = ParseTrailingDecimalNumber(spec.id))
  {
    return FormatDerivedEndpointMac(*ordinal);
  }

  return FormatDerivedEndpointMac(static_cast<uint32_t>(instanceIndex + 1));
}

void
ValidateTopologyConfig(const TopologyConfig &cfg)
{
  if (cfg.globals.pcap)
  {
    Fatal("globals.pcap=true requested, but pcap capture is not implemented "
          "in this checkpoint; set globals.pcap=false");
  }

  RequireSafeIdentifier(cfg.globals.scenarioId, "scenario_id");
  RequireSafeIdentifier(cfg.globals.gsId, "globals.gs_id");
  RequireSafeIdentifier(cfg.globals.tapLeft, "globals.tap_left");
  RequireTimeString(cfg.globals.tick, "globals.tick", true);
  RequireDataRateString(cfg.globals.defaultDataRate,
                        "globals.default_data_rate");
  RequireDataRateString(cfg.globals.defaultAccessDataRate,
                        "globals.default_access_data_rate");
  RequireTimeString(cfg.globals.defaultDelay, "globals.default_delay", false);
  RequireTimeString(cfg.globals.defaultAccessDelay,
                    "globals.default_access_delay",
                    false);

  if (cfg.globals.fabricMode != "l2_link_mesh")
  {
    Fatal("l2 mesh only supports globals.fabric_mode = l2_link_mesh");
  }

  if (cfg.globals.impairmentPolicy != "ns3_access_links" &&
      cfg.globals.impairmentPolicy != "linux_pairwise_tc" &&
      cfg.globals.impairmentPolicy != "ns3_pairwise_links" &&
      cfg.globals.impairmentPolicy != "ns3_wifi_ad_hoc")
  {
    Fatal("unsupported globals.experiment_net.impairment_policy: " +
          cfg.globals.impairmentPolicy);
  }

  if (cfg.linkSimulation.enabled &&
      cfg.linkSimulation.model != "ns3_buildings_pathloss" &&
      cfg.linkSimulation.model != "large_small_fading_v1")
  {
    Fatal("unsupported globals.link_simulation.model: " + cfg.linkSimulation.model);
  }

  if (cfg.globals.Ns3WifiAdhoc() && !cfg.linkSimulation.LargeSmallFading())
  {
    Fatal("ns3_wifi_ad_hoc requires globals.link_simulation.model=large_small_fading_v1");
  }

  if (cfg.linkSimulation.Ns3BuildingsPathloss() || cfg.linkSimulation.LargeSmallFading())
  {
    const bool nativeWifi = cfg.globals.Ns3WifiAdhoc();
    if (!nativeWifi &&
        cfg.linkSimulation.linkErrorModel != "snr_packet_error_v1" &&
        !cfg.linkSimulation.ReceiverSensitivityBler() &&
        cfg.linkSimulation.linkErrorModel != "linear_rx_threshold_v1")
    {
      Fatal("unsupported globals.link_simulation.link_layer.error_model: " +
            cfg.linkSimulation.linkErrorModel);
    }
    if (!std::isfinite(cfg.linkSimulation.noiseFloorDbm))
    {
      Fatal("globals.link_simulation.link_layer.noise_floor_dbm must be finite");
    }
    if (cfg.linkSimulation.packetErrorBytes <= 0.0)
    {
      Fatal("globals.link_simulation.link_layer.packet_error_bytes must be > 0");
    }
    if (!std::isfinite(cfg.linkSimulation.codingGainDb))
    {
      Fatal("globals.link_simulation.link_layer.coding_gain_db must be finite");
    }
    if (std::isfinite(cfg.linkSimulation.mcsSensitivity10PerDbm) &&
        (cfg.linkSimulation.mcsSensitivity10PerDbm <= -150.0 ||
         cfg.linkSimulation.mcsSensitivity10PerDbm >= -20.0))
    {
      Fatal("globals.link_simulation.link_layer.mcs_per10_sensitivity_dbm must be in (-150, -20)");
    }
    if (!std::isfinite(cfg.linkSimulation.implementationMarginDb))
    {
      Fatal("globals.link_simulation.link_layer.implementation_margin_db must be finite");
    }
    if (cfg.linkSimulation.blerTransitionDb <= 0.0 ||
        !std::isfinite(cfg.linkSimulation.blerTransitionDb))
    {
      Fatal("globals.link_simulation.link_layer.bler_transition_db must be > 0");
    }
    if (cfg.linkSimulation.packetErrorRateCap < 0.0 ||
        cfg.linkSimulation.packetErrorRateCap > 1.0 ||
        !std::isfinite(cfg.linkSimulation.packetErrorRateCap))
    {
      Fatal("globals.link_simulation.link_layer.per_cap must be in [0, 1]");
    }
    if (cfg.linkSimulation.packetErrorSmoothingTauS < 0.0 ||
        !std::isfinite(cfg.linkSimulation.packetErrorSmoothingTauS))
    {
      Fatal("globals.link_simulation.link_layer.per_smoothing_tau_s must be >= 0");
    }
    if (!nativeWifi && cfg.linkSimulation.ReceiverSensitivityBler())
    {
      (void)ResolveMcsProfile(cfg.linkSimulation);
    }
    if (nativeWifi)
    {
      (void)ResolveWifiStandard(cfg.linkSimulation.wifiStandard);
      if (cfg.linkSimulation.wifiMacType != "ns3::AdhocWifiMac")
      {
        Fatal("ns3_wifi_ad_hoc currently supports wifi.mac=ns3::AdhocWifiMac only");
      }
      if (cfg.linkSimulation.wifiTapBridgeMode != "UseBridge")
      {
        Fatal("ns3_wifi_ad_hoc requires wifi.tap_bridge_mode=UseBridge");
      }
      if (!std::isfinite(cfg.linkSimulation.wifiCcaEdThresholdDbm))
      {
        Fatal("globals.link_simulation.wifi.cca_ed_threshold_dbm must be finite");
      }
      if (!std::isfinite(cfg.linkSimulation.txPowerDbm) ||
          !std::isfinite(cfg.linkSimulation.WifiRxSensitivityDbm()))
      {
        Fatal("ns3_wifi_ad_hoc requires finite tx_power_dbm and "
              "wifi.rx_sensitivity_dbm");
      }
    }
    else if (cfg.linkSimulation.macModel != "l2_arq_state_machine_v1")
    {
      Fatal("unsupported globals.link_simulation.mac.model: " +
            cfg.linkSimulation.macModel);
    }
    if (!nativeWifi &&
        cfg.linkSimulation.macMediumAccess != "pairwise_serial_arq_v1" &&
        cfg.linkSimulation.macMediumAccess != "shared_radio_serial_dcf_v1")
    {
      Fatal("unsupported globals.link_simulation.mac.medium_access: " +
            cfg.linkSimulation.macMediumAccess);
    }
    if (!nativeWifi &&
        cfg.linkSimulation.macQueueModel != "bounded_per_link_pending_queue" &&
        cfg.linkSimulation.macQueueModel != "per_link_fifo")
    {
      Fatal("unsupported globals.link_simulation.mac.queue_model: " +
            cfg.linkSimulation.macQueueModel);
    }
    if (!nativeWifi &&
        cfg.linkSimulation.macAckModel !=
        "abstract_unicast_ack_no_independent_ack_phy")
    {
      Fatal("unsupported globals.link_simulation.mac.ack_model: " +
            cfg.linkSimulation.macAckModel);
    }
    if (!nativeWifi && cfg.linkSimulation.macQueueLimitPackets == 0)
    {
      Fatal("globals.link_simulation.mac.queue_limit_packets must be > 0");
    }
    if (!nativeWifi && cfg.linkSimulation.rxSensitivityDbm <= cfg.linkSimulation.rxLossFullDbm)
    {
      Fatal("globals.link_simulation.rx_sensitivity_dbm must be greater than rx_loss_full_dbm");
    }
    if (cfg.linkSimulation.frequencyHz <= 0.0)
    {
      Fatal("globals.link_simulation.frequency_hz must be > 0");
    }
    RequireDataRateString(cfg.linkSimulation.macDataRate,
                          "globals.link_simulation.mac.data_rate");
    RequireTimeString(cfg.linkSimulation.macRetrySlotTime,
                      "globals.link_simulation.mac.retry.slot_time",
                      true);
    RequireTimeString(cfg.linkSimulation.macRetryJitterMax,
                      "globals.link_simulation.mac.retry.jitter_max",
                      false);
  }

  if (cfg.linkSimulation.LargeSmallFading())
  {
    if (cfg.linkSimulation.pathLossModel != "ns3::LogDistancePropagationLossModel")
    {
      Fatal("large_small_fading_v1 currently supports path_loss.model="
            "ns3::LogDistancePropagationLossModel only");
    }
    if (cfg.linkSimulation.pathLossExponent <= 0.0)
    {
      Fatal("globals.link_simulation.large_scale.path_loss.exponent must be > 0");
    }
    if (cfg.linkSimulation.pathLossReferenceDistanceM <= 0.0)
    {
      Fatal("globals.link_simulation.large_scale.path_loss.reference_distance_m must be > 0");
    }
    if (cfg.linkSimulation.pathLossReferenceLossDb < 0.0)
    {
      Fatal("globals.link_simulation.large_scale.path_loss.reference_loss_db must be >= 0");
    }
    if (cfg.linkSimulation.shadowFadingStddevDb < 0.0)
    {
      Fatal("globals.link_simulation.large_scale.shadow_fading.stddev_db must be >= 0");
    }
    if (cfg.linkSimulation.shadowFadingCorrelationDistanceM <= 0.0)
    {
      Fatal("globals.link_simulation.large_scale.shadow_fading.correlation_distance_m must be > 0");
    }
    if (cfg.linkSimulation.obstructionBaseLossDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionBaseLossDb))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.base_loss_db must be >= 0");
    }
    if (cfg.linkSimulation.obstructionLossPerHitDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionLossPerHitDb))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.loss_per_hit_db must be >= 0");
    }
    if (cfg.linkSimulation.obstructionLossPerMeterDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionLossPerMeterDb))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.loss_per_meter_db must be >= 0");
    }
    if (cfg.linkSimulation.obstructionLossMaxDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionLossMaxDb))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.max_loss_db must be >= 0");
    }
    if (cfg.linkSimulation.obstructionMinIntersectionM < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionMinIntersectionM))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.min_intersection_m must be >= 0");
    }
    if (cfg.linkSimulation.obstructionDiffractionMarginM < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionDiffractionMarginM))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.diffraction_margin_m must be >= 0");
    }
    if (cfg.linkSimulation.obstructionDiffractionLossDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionDiffractionLossDb))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.diffraction_loss_db must be >= 0");
    }
    if (cfg.linkSimulation.obstructionEdgeRampM < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionEdgeRampM))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.edge_ramp_m must be >= 0");
    }
    if (cfg.linkSimulation.obstructionSmoothingTauS < 0.0 ||
        !std::isfinite(cfg.linkSimulation.obstructionSmoothingTauS))
    {
      Fatal("globals.link_simulation.large_scale.obstruction.smoothing_tau_s must be >= 0");
    }
    if (cfg.linkSimulation.multipathFadingEnabled &&
        cfg.linkSimulation.multipathModel != "ns3::NakagamiPropagationLossModel")
    {
      Fatal("large_small_fading_v1 currently supports small_scale.multipath.model="
            "ns3::NakagamiPropagationLossModel only");
    }
    if (cfg.linkSimulation.multipathMinRelativeSpeedMps < 0.0)
    {
      Fatal("globals.link_simulation.small_scale.multipath.min_relative_speed_mps must be >= 0");
    }
    if (cfg.linkSimulation.multipathCoherenceDistanceM <= 0.0)
    {
      Fatal("globals.link_simulation.small_scale.multipath.coherence_distance_m must be > 0");
    }
    if (cfg.linkSimulation.multipathCoherenceTimeS <= 0.0)
    {
      Fatal("globals.link_simulation.small_scale.multipath.coherence_time_s must be > 0");
    }
    if (cfg.linkSimulation.multipathMaxLossDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.multipathMaxLossDb))
    {
      Fatal("globals.link_simulation.small_scale.multipath.max_loss_db must be >= 0");
    }
    if (cfg.linkSimulation.multipathMaxGainDb < 0.0 ||
        !std::isfinite(cfg.linkSimulation.multipathMaxGainDb))
    {
      Fatal("globals.link_simulation.small_scale.multipath.max_gain_db must be >= 0");
    }
    if (cfg.linkSimulation.multipathSmoothingTauS < 0.0 ||
        !std::isfinite(cfg.linkSimulation.multipathSmoothingTauS))
    {
      Fatal("globals.link_simulation.small_scale.multipath.smoothing_tau_s must be >= 0");
    }
    if (cfg.linkSimulation.nakagamiDistance1M < 0.0 ||
        cfg.linkSimulation.nakagamiDistance2M < cfg.linkSimulation.nakagamiDistance1M)
    {
      Fatal("Nakagami distances must satisfy 0 <= distance1_m <= distance2_m");
    }
    if (cfg.linkSimulation.nakagamiM0 <= 0.0 ||
        cfg.linkSimulation.nakagamiM1 <= 0.0 ||
        cfg.linkSimulation.nakagamiM2 <= 0.0)
    {
      Fatal("Nakagami m parameters must be > 0");
    }
    if (cfg.linkSimulation.dopplerFadingEnabled &&
        cfg.linkSimulation.dopplerModel != "ns3::JakesPropagationLossModel")
    {
      Fatal("large_small_fading_v1 currently supports small_scale.doppler.model="
            "ns3::JakesPropagationLossModel only");
    }
    if (cfg.linkSimulation.dopplerMinRelativeSpeedMps < 0.0)
    {
      Fatal("globals.link_simulation.small_scale.doppler.min_relative_speed_mps must be >= 0");
    }
    if (cfg.linkSimulation.jakesDopplerHz < 0.0)
    {
      Fatal("globals.link_simulation.small_scale.doppler.doppler_frequency_hz must be >= 0");
    }
  }

  if (cfg.globals.gsId.empty())
  {
    Fatal("globals.gs_id is required");
  }

  if (cfg.globals.tapLeft.empty())
  {
    Fatal("globals.tap_left is required");
  }

  if (cfg.globals.timeFile.empty())
  {
    Fatal("globals.time_file is required");
  }

  const auto &gs = FindGroundStation(cfg);

  if (gs.tapName.empty())
  {
    Fatal("ground_station instance must define tap_name");
  }

  if (gs.tapName != cfg.globals.tapLeft)
  {
    Fatal("ground_station tap_name must match globals.tap_left");
  }

  std::set<std::string> ids;
  std::set<std::string> taps;
  std::set<std::string> endpointMacs;
  std::map<std::string, std::string> typeById;

  for (const auto &inst : cfg.instances)
  {
    if (inst.id.empty())
    {
      Fatal("instance id must not be empty");
    }
    RequireSafeIdentifier(inst.id, "instance id");

    if (!ids.insert(inst.id).second)
    {
      Fatal("duplicate instance id: " + inst.id);
    }

    if (inst.tapName.empty())
    {
      Fatal("instance tap_name must not be empty: " + inst.id);
    }
    RequireSafeIdentifier(inst.tapName, "instance tap_name for " + inst.id);

    if (!taps.insert(inst.tapName).second)
    {
      Fatal("duplicate tap_name: " + inst.tapName);
    }

    if (inst.endpointMacAddress.empty())
    {
      Fatal("instance endpoint MAC must not be empty: " + inst.id);
    }

    if (!IsValidMacAddress(inst.endpointMacAddress))
    {
      Fatal("invalid endpoint MAC for instance " + inst.id + ": " +
            inst.endpointMacAddress);
    }

    if (!endpointMacs.insert(inst.endpointMacAddress).second)
    {
      Fatal("duplicate endpoint MAC: " + inst.endpointMacAddress);
    }

    if (inst.type != "ground_station" && inst.type != "uav")
    {
      Fatal("unsupported instance type in l2 mesh: " + inst.type);
    }

    typeById[inst.id] = inst.type;
  }

  auto enabledLinks = GetEnabledGsUavLinks(cfg);
  if (enabledLinks.empty())
  {
    Fatal("no enabled gs->uav access links found");
  }

  std::set<std::string> linkIds;
  for (const auto &link : cfg.links)
  {
    if (link.id.empty())
    {
      Fatal("link id must not be empty");
    }
    RequireSafeIdentifier(link.id, "link id");
    RequireSafeIdentifier(link.src, "link src for " + link.id);
    RequireSafeIdentifier(link.dst, "link dst for " + link.id);
    RequireDataRateString(link.dataRate, "link data_rate for " + link.id);
    RequireTimeString(link.baseDelay, "link base_delay for " + link.id, false);
    RequireTimeString(link.jitterPerMps, "link jitter_per_mps for " + link.id, false);
    RequireTimeString(link.jitterMax, "link jitter_max for " + link.id, false);
    if (!std::isfinite(link.lossMin) || !std::isfinite(link.lossMax) ||
        link.lossMin < 0.0 || link.lossMin > 1.0 ||
        link.lossMax < 0.0 || link.lossMax > 1.0 ||
        link.lossMin > link.lossMax)
    {
      Fatal("link loss_min/loss_max must be finite, in [0, 1], and loss_min <= loss_max: " +
            link.id);
    }
    if (!std::isfinite(link.distNoLoss) || !std::isfinite(link.distMax) ||
        link.distNoLoss < 0.0 || link.distMax < 0.0 ||
        link.distNoLoss > link.distMax)
    {
      Fatal("link dist_no_loss/dist_max must be finite, non-negative, and dist_no_loss <= dist_max: " +
            link.id);
    }

    if (!linkIds.insert(link.id).second)
    {
      Fatal("duplicate link id: " + link.id);
    }

    if (!link.enabled)
    {
      continue;
    }

    if (link.src != cfg.globals.gsId)
    {
      Fatal("l2 mesh access links must use src == globals.gs_id; bad link: " + link.id);
    }

    auto it = typeById.find(link.dst);
    if (it == typeById.end())
    {
      Fatal("enabled link dst does not exist in instances: " + link.id);
    }

    if (it->second != "uav")
    {
      Fatal("l2 mesh access links must run from gs to uav; bad link: " + link.id);
    }

    if (link.metricsFile.empty())
    {
      Fatal("enabled gs->uav access link must define metrics_file: " + link.id);
    }
  }

  for (const auto &link : cfg.meshLinks)
  {
    if (link.id.empty())
    {
      Fatal("mesh link id must not be empty");
    }
    RequireSafeIdentifier(link.id, "mesh link id");
    RequireSafeIdentifier(link.src, "mesh link src for " + link.id);
    RequireSafeIdentifier(link.dst, "mesh link dst for " + link.id);
    RequireDataRateString(link.dataRate, "mesh link data_rate for " + link.id);
    RequireTimeString(link.baseDelay, "mesh link base_delay for " + link.id, false);
    RequireTimeString(link.jitterPerMps, "mesh link jitter_per_mps for " + link.id, false);
    RequireTimeString(link.jitterMax, "mesh link jitter_max for " + link.id, false);
    if (!std::isfinite(link.lossMin) || !std::isfinite(link.lossMax) ||
        link.lossMin < 0.0 || link.lossMin > 1.0 ||
        link.lossMax < 0.0 || link.lossMax > 1.0 ||
        link.lossMin > link.lossMax)
    {
      Fatal("mesh link loss_min/loss_max must be finite, in [0, 1], and loss_min <= loss_max: " +
            link.id);
    }
    if (!std::isfinite(link.distNoLoss) || !std::isfinite(link.distMax) ||
        link.distNoLoss < 0.0 || link.distMax < 0.0 ||
        link.distNoLoss > link.distMax)
    {
      Fatal("mesh link dist_no_loss/dist_max must be finite, non-negative, and dist_no_loss <= dist_max: " +
            link.id);
    }

    if (!linkIds.insert(link.id).second)
    {
      Fatal("duplicate link id: " + link.id);
    }

    if (!link.enabled)
    {
      continue;
    }

    if (link.src == link.dst)
    {
      Fatal("enabled mesh link cannot be a self-link: " + link.id);
    }

    auto srcIt = typeById.find(link.src);
    auto dstIt = typeById.find(link.dst);
    if (srcIt == typeById.end() || dstIt == typeById.end())
    {
      Fatal("enabled mesh link endpoint does not exist in instances: " + link.id);
    }

    if (srcIt->second != "uav" || dstIt->second != "uav")
    {
      Fatal("mesh_links[] must connect uav endpoints only: " + link.id);
    }

    if (link.metricsFile.empty())
    {
      Fatal("enabled mesh link must define metrics_file: " + link.id);
    }
  }

  if (cfg.globals.EndpointPairLinkImpairment())
  {
    std::set<std::string> endpointIds;
    for (const auto &inst : cfg.instances)
    {
      endpointIds.insert(inst.id);
    }

    std::set<std::string> pairKeys;
    for (const auto &link : GetEnabledPairwiseLinks(cfg))
    {
      const std::string key = EndpointPairKey(link.src, link.dst);
      if (!pairKeys.insert(key).second)
      {
        Fatal("duplicate enabled endpoint metric pair: " + link.id);
      }
    }

    for (auto itA = endpointIds.begin(); itA != endpointIds.end(); ++itA)
    {
      auto itB = itA;
      ++itB;
      for (; itB != endpointIds.end(); ++itB)
      {
        const std::string key = EndpointPairKey(*itA, *itB);
        if (pairKeys.find(key) == pairKeys.end())
        {
          Fatal("endpoint metric pair required for MatrixPropagationLossModel: " +
                *itA + " <-> " + *itB);
        }
      }
    }
  }
}

const InstanceSpec &
FindGroundStation(const TopologyConfig &cfg)
{
  const InstanceSpec *gs = nullptr;

  for (const auto &inst : cfg.instances)
  {
    if (inst.type == "ground_station")
    {
      if (gs != nullptr)
      {
        Fatal("l2 mesh supports exactly one ground_station instance");
      }
      gs = &inst;
    }
  }

  if (gs == nullptr)
  {
    Fatal("no ground_station instance found");
  }

  if (gs->id != cfg.globals.gsId)
  {
    Fatal("globals.gs_id does not match the single ground_station instance id");
  }

  return *gs;
}

std::vector<InstanceSpec>
GetUavInstances(const TopologyConfig &cfg)
{
  std::vector<InstanceSpec> out;
  for (const auto &inst : cfg.instances)
  {
    if (inst.type == "uav")
    {
      out.push_back(inst);
    }
  }
  return out;
}

std::vector<LinkSpec>
GetEnabledGsUavLinks(const TopologyConfig &cfg)
{
  std::vector<LinkSpec> out;
  for (const auto &link : cfg.links)
  {
    if (!link.enabled)
    {
      continue;
    }

    if (link.src == cfg.globals.gsId)
    {
      out.push_back(link);
    }
  }
  return out;
}

std::vector<LinkSpec>
GetEnabledPairwiseLinks(const TopologyConfig &cfg)
{
  std::vector<LinkSpec> out;
  for (const auto &link : cfg.links)
  {
    if (link.enabled)
    {
      out.push_back(link);
    }
  }
  for (const auto &link : cfg.meshLinks)
  {
    if (link.enabled)
    {
      out.push_back(link);
    }
  }
  return out;
}

TopologyRuntime
BuildTopology(const TopologyConfig &cfg)
{
  TopologyRuntime rt;
  rt.config = cfg;
  rt.verbose = cfg.globals.verbose;
  rt.pcapEnabled = cfg.globals.pcap;

  for (const auto &inst : cfg.instances)
  {
    rt.instanceMap.emplace(inst.id, inst);
  }

  SetupBuildingsPathloss(rt);
  SetupLargeSmallFading(rt);
  if (cfg.globals.Ns3WifiAdhoc())
  {
    BuildPairwiseLinks(rt);
    CreateWifiAdhocFabric(rt);
    RefreshSharedMetricsSnapshot(rt);
    UpdateWifiAdhocLinks(rt);
    EnablePcapIfNeeded(rt);
    return rt;
  }
  CreateCoreBridge(rt);
  CreateGsIngress(rt);
  CreateUavAccessLinks(rt);
  EnablePcapIfNeeded(rt);

  return rt;
}

void
SetupBuildingsPathloss(TopologyRuntime &rt)
{
  const auto &sim = rt.config.linkSimulation;
  if (!sim.Ns3BuildingsPathloss())
  {
    return;
  }

  for (const auto &obs : sim.obstacles)
  {
    Ptr<Building> building = CreateObject<Building>();
    const double hx = obs.size.x / 2.0;
    const double hy = obs.size.y / 2.0;
    const double hz = obs.size.z / 2.0;
    building->SetBoundaries(Box(obs.center.x - hx,
                                obs.center.x + hx,
                                obs.center.y - hy,
                                obs.center.y + hy,
                                obs.center.z - hz,
                                obs.center.z + hz));
    building->SetBuildingType(ParseBuildingType(obs.buildingType));
    building->SetExtWallsType(ParseExtWallsType(obs.extWallsType));
    building->SetNRoomsX(1);
    building->SetNRoomsY(1);
    building->SetNFloors(obs.floors);
  }

  for (const auto &inst : rt.config.instances)
  {
    Ptr<ConstantPositionMobilityModel> mobility =
        CreateObject<ConstantPositionMobilityModel>();
    const Vector initialPosition =
        (inst.type == "ground_station") ? rt.config.globals.gsPose : Vector(0.0, 0.0, 0.0);
    mobility->SetPosition(initialPosition);

    Ptr<MobilityBuildingInfo> buildingInfo = CreateObject<MobilityBuildingInfo>();
    mobility->AggregateObject(buildingInfo);
    buildingInfo->MakeConsistent(mobility);

    rt.endpointMobility.emplace(inst.id, mobility);
    rt.endpointBuildingInfo.emplace(inst.id, buildingInfo);
  }

  rt.channelConditionModel = CreateChannelConditionModel(sim.channelConditionModel);
  rt.propagationLossModel = CreatePropagationLossModel(sim.propagationLossModel);

  Ptr<ThreeGppPropagationLossModel> threeGpp =
      rt.propagationLossModel->GetObject<ThreeGppPropagationLossModel>();
  if (threeGpp != nullptr)
  {
    threeGpp->SetChannelConditionModel(rt.channelConditionModel);
    threeGpp->SetFrequency(sim.frequencyHz);
    threeGpp->SetAttribute("ShadowingEnabled", BooleanValue(sim.shadowingEnabled));
  }

  std::ostringstream oss;
  oss << "[build] ns-3 buildings pathloss enabled"
      << " propagation=" << sim.propagationLossModel
      << " condition=" << sim.channelConditionModel
      << " obstacles=" << sim.obstacles.size()
      << " frequency_hz=" << sim.frequencyHz
      << " shadowing=" << (sim.shadowingEnabled ? 1 : 0);
  LogInfo(oss.str(), rt.verbose);
}

void
SetupLargeSmallFading(TopologyRuntime &rt)
{
  const auto &sim = rt.config.linkSimulation;
  if (!sim.LargeSmallFading())
  {
    return;
  }

  rt.fadingSrcMobility = CreateObject<ConstantPositionMobilityModel>();
  rt.fadingDstMobility = CreateObject<ConstantPositionMobilityModel>();
  rt.fadingSrcMobility->SetPosition(Vector(0.0, 0.0, 0.0));
  rt.fadingDstMobility->SetPosition(Vector(sim.pathLossReferenceDistanceM, 0.0, 0.0));

  rt.largeSmallPathLossModel = CreateObject<LogDistancePropagationLossModel>();
  rt.largeSmallPathLossModel->SetPathLossExponent(sim.pathLossExponent);
  rt.largeSmallPathLossModel->SetReference(sim.pathLossReferenceDistanceM,
                                           sim.pathLossReferenceLossDb);

  if (sim.multipathFadingEnabled)
  {
    rt.largeSmallMultipathModel = CreateObject<NakagamiPropagationLossModel>();
    rt.largeSmallMultipathModel->SetAttribute("Distance1",
                                              DoubleValue(sim.nakagamiDistance1M));
    rt.largeSmallMultipathModel->SetAttribute("Distance2",
                                              DoubleValue(sim.nakagamiDistance2M));
    rt.largeSmallMultipathModel->SetAttribute("m0", DoubleValue(sim.nakagamiM0));
    rt.largeSmallMultipathModel->SetAttribute("m1", DoubleValue(sim.nakagamiM1));
    rt.largeSmallMultipathModel->SetAttribute("m2", DoubleValue(sim.nakagamiM2));
  }

  // The accepted current topology keeps Doppler disabled. Relative speed may
  // affect statistical decorrelation, multipath refresh, and delay jitter, but
  // Doppler is not treated as an additional deterministic dB-loss term.
  if (sim.dopplerFadingEnabled)
  {
    Config::SetDefault("ns3::JakesProcess::DopplerFrequencyHz",
                       DoubleValue(sim.jakesDopplerHz));
    Config::SetDefault("ns3::JakesProcess::NumberOfOscillators",
                       UintegerValue(sim.jakesOscillators));
    rt.largeSmallDopplerModel = CreatePropagationLossModel(sim.dopplerModel);
  }

  rt.shadowNormalRng = CreateObject<NormalRandomVariable>();
  rt.shadowNormalRng->SetAttribute("Mean", DoubleValue(0.0));
  rt.shadowNormalRng->SetAttribute("Variance", DoubleValue(1.0));

  std::ostringstream oss;
  const auto mcsProfile =
      sim.ReceiverSensitivityBler() ? LookupMcsProfile(sim.mcs) : std::nullopt;
  oss << "[build] link simulation model=large_small_fading_v1"
      << " model_scope=protocol_stack_aware_uav_link_traffic_impairment"
      << " path_loss=" << sim.pathLossModel
      << " exponent=" << sim.pathLossExponent
      << " reference_distance_m=" << sim.pathLossReferenceDistanceM
      << " reference_loss_db=" << sim.pathLossReferenceLossDb
      << " reference_loss_source="
      << (sim.pathLossReferenceLossDbExplicit ? "explicit" : "fspl_1m_from_frequency")
      << " frequency_hz=" << sim.frequencyHz
      << " shadow_fading=" << (sim.shadowFadingEnabled ? 1 : 0)
      << " shadow_stddev_db=" << sim.shadowFadingStddevDb
      << " obstruction=" << (sim.obstructionLossEnabled ? 1 : 0)
      << " obstruction_base_loss_db=" << sim.obstructionBaseLossDb
      << " obstruction_loss_per_hit_db=" << sim.obstructionLossPerHitDb
      << " obstruction_loss_per_meter_db=" << sim.obstructionLossPerMeterDb
      << " obstruction_max_loss_db=" << sim.obstructionLossMaxDb
      << " obstruction_min_intersection_m=" << sim.obstructionMinIntersectionM
      << " obstruction_diffraction_margin_m=" << sim.obstructionDiffractionMarginM
      << " obstruction_diffraction_loss_db=" << sim.obstructionDiffractionLossDb
      << " obstruction_edge_ramp_m=" << sim.obstructionEdgeRampM
      << " obstruction_smoothing_tau_s=" << sim.obstructionSmoothingTauS
      << " obstacles=" << sim.obstacles.size()
      << " multipath=" << (sim.multipathFadingEnabled ? sim.multipathModel : "disabled")
      << " multipath_min_speed_mps=" << sim.multipathMinRelativeSpeedMps
      << " multipath_coherence_distance_m=" << sim.multipathCoherenceDistanceM
      << " multipath_coherence_time_s=" << sim.multipathCoherenceTimeS
      << " multipath_max_loss_db=" << sim.multipathMaxLossDb
      << " multipath_max_gain_db=" << sim.multipathMaxGainDb
      << " multipath_smoothing_tau_s=" << sim.multipathSmoothingTauS
      << " doppler=" << (sim.dopplerFadingEnabled ? sim.dopplerModel : "disabled")
      << " doppler_scope=no_extra_db_loss_when_disabled"
      << " tx_power_dbm=" << sim.txPowerDbm
      << " legacy_rx_sensitivity_dbm=" << sim.rxSensitivityDbm
      << " rx_loss_full_dbm_compat=" << sim.rxLossFullDbm
      << " wifi_rx_sensitivity_dbm=" << sim.WifiRxSensitivityDbm()
      << " link_error_model=" << sim.linkErrorModel
      << " phy_model=" << sim.phyModel
      << " phy_abstraction=" << sim.phyAbstraction
      << " noise_floor_dbm=" << sim.noiseFloorDbm
      << " packet_error_bytes=" << sim.packetErrorBytes
      << " coding_gain_db=" << sim.codingGainDb
      << " per_cap=" << sim.packetErrorRateCap
      << " per_smoothing_tau_s=" << sim.packetErrorSmoothingTauS
      << " packet_size_scaling=" << (sim.packetSizeScalingEnabled ? 1 : 0)
      << " mac_model=" << sim.macModel
      << " mac_medium_access=" << sim.macMediumAccess
      << " mac_queue_model=" << sim.macQueueModel
      << " mac_ack_model=" << sim.macAckModel
      << " mac_data_rate=" << sim.macDataRate
      << " mac_queue_limit_packets=" << sim.macQueueLimitPackets
      << " mac_airtime_accounting=" << (sim.macAirtimeAccounting ? 1 : 0)
      << " mac_retry=" << (sim.macRetryEnabled ? 1 : 0)
      << " mac_retry_max_retries=" << sim.macRetryMaxRetries
      << " mac_retry_slot_time=" << sim.macRetrySlotTime
      << " mac_retry_jitter_max=" << sim.macRetryJitterMax
      << " mac_retry_broadcast=" << (sim.macRetryBroadcast ? 1 : 0);
  if (mcsProfile.has_value())
  {
    oss << " mcs=" << mcsProfile->name
        << " modulation_bits=" << mcsProfile->modulationBitsPerSymbol
        << " coding_rate=" << mcsProfile->codingRate
        << " mcs_per10_sensitivity_dbm=" << mcsProfile->sensitivity10PerDbm
        << " implementation_margin_db=" << sim.implementationMarginDb
        << " bler_transition_db=" << sim.blerTransitionDb;
  }
  LogInfo(oss.str(), rt.verbose);
}

void
CreateCoreBridge(TopologyRuntime &rt)
{
  rt.coreNode = CreateObject<Node>();
  LogInfo("[build] created core node", rt.verbose);
}

void
CreateGsIngress(TopologyRuntime &rt)
{
  const auto &cfg = rt.config;
  const auto &gs = FindGroundStation(cfg);

  rt.gsPortNode = CreateObject<Node>();

  const bool dynamicImpairment = cfg.globals.DynamicAccessImpairment();
  const std::string channelRate =
      dynamicImpairment ? cfg.globals.defaultDataRate : cfg.globals.defaultAccessDataRate;
  const std::string channelDelay =
      dynamicImpairment ? cfg.globals.defaultDelay : cfg.globals.defaultAccessDelay;

  CsmaHelper csma;
  csma.SetChannelAttribute(
      "DataRate",
      DataRateValue(ParseDataRateOrDefault(channelRate, "1Gbps")));
  csma.SetChannelAttribute(
      "Delay",
      TimeValue(ParseTimeOrDefault(channelDelay, MilliSeconds(0))));

  NodeContainer pair(rt.gsPortNode, rt.coreNode);
  NetDeviceContainer devs = csma.Install(pair);

  if (devs.GetN() != 2)
  {
    Fatal("failed to create GS ingress Csma edge");
  }

  rt.gsEdgeDevice = devs.Get(0);
  rt.gsCoreSideDevice = devs.Get(1);
  rt.gsIngressChannel = DynamicCast<CsmaChannel>(rt.gsEdgeDevice->GetChannel());

  if (rt.gsIngressChannel == nullptr)
  {
    Fatal("failed to cast GS ingress channel to CsmaChannel");
  }

  rt.corePortDevices.Add(rt.gsCoreSideDevice);
  RegisterCorePort(rt, gs.id, rt.gsCoreSideDevice);

  TapBridgeHelper tap;
  tap.SetAttribute("Mode", StringValue("UseBridge"));
  tap.SetAttribute("DeviceName", StringValue(gs.tapName));
  Ptr<NetDevice> tapDev = tap.Install(rt.gsPortNode, rt.gsEdgeDevice);
  rt.gsTapBridge = DynamicCast<TapBridge>(tapDev);

  if (rt.gsTapBridge == nullptr)
  {
    Fatal("failed to install GS TapBridge");
  }

  LogInfo("[bind] gs " + gs.tapName, rt.verbose);
}

void
CreateUavAccessLinks(TopologyRuntime &rt)
{
  for (const auto &link : GetEnabledGsUavLinks(rt.config))
  {
    auto it = rt.instanceMap.find(link.dst);
    if (it == rt.instanceMap.end())
    {
      Fatal("link dst instance not found during build: " + link.dst);
    }

    const auto &inst = it->second;

    LinkRuntime lr;
    lr.spec = link;
    lr.jitterRng = CreateObject<UniformRandomVariable>();
    lr.jitterRng->SetAttribute("Min", DoubleValue(-1.0));
    lr.jitterRng->SetAttribute("Max", DoubleValue(1.0));
    lr.edgeNode = CreateObject<Node>();
    rt.uavEdgeNodeMap.emplace(inst.id, lr.edgeNode);

    const bool dynamicImpairment = rt.config.globals.DynamicAccessImpairment();
    const std::string channelRate =
        dynamicImpairment ? link.dataRate : rt.config.globals.defaultAccessDataRate;
    const std::string channelDelay =
        dynamicImpairment ? link.baseDelay : rt.config.globals.defaultAccessDelay;

    CsmaHelper csma;
    csma.SetChannelAttribute(
        "DataRate",
        DataRateValue(ParseDataRateOrDefault(channelRate,
                                             rt.config.globals.defaultAccessDataRate)));
    csma.SetChannelAttribute(
        "Delay",
        TimeValue(ParseTimeOrDefault(channelDelay, MilliSeconds(0))));

    NodeContainer pair(lr.edgeNode, rt.coreNode);
    NetDeviceContainer devs = csma.Install(pair);

    if (devs.GetN() != 2)
    {
      Fatal("failed to create Csma edge for link: " + link.id);
    }

    lr.edgeDevice = devs.Get(0);
    lr.coreSideDevice = devs.Get(1);
    lr.channel = DynamicCast<CsmaChannel>(lr.edgeDevice->GetChannel());
    lr.currentDelay = ParseTimeOrDefault(channelDelay, MilliSeconds(0));

    if (lr.channel == nullptr)
    {
      Fatal("failed to cast link channel to CsmaChannel: " + link.id);
    }

    lr.edgeRxErrorModel = CreateObject<RateErrorModel>();
    lr.edgeRxErrorModel->SetUnit(RateErrorModel::ERROR_UNIT_PACKET);
    lr.edgeRxErrorModel->SetRate(0.0);
    lr.edgeDevice->SetAttribute("ReceiveErrorModel", PointerValue(lr.edgeRxErrorModel));

    lr.coreRxErrorModel = CreateObject<RateErrorModel>();
    lr.coreRxErrorModel->SetUnit(RateErrorModel::ERROR_UNIT_PACKET);
    lr.coreRxErrorModel->SetRate(0.0);
    lr.coreSideDevice->SetAttribute("ReceiveErrorModel", PointerValue(lr.coreRxErrorModel));

    rt.corePortDevices.Add(lr.coreSideDevice);
    RegisterCorePort(rt, inst.id, lr.coreSideDevice);

    TapBridgeHelper tap;
    tap.SetAttribute("Mode", StringValue("UseBridge"));
    tap.SetAttribute("DeviceName", StringValue(inst.tapName));
    Ptr<NetDevice> tapDev = tap.Install(lr.edgeNode, lr.edgeDevice);
    lr.tapBridge = DynamicCast<TapBridge>(tapDev);

    if (lr.tapBridge == nullptr)
    {
      Fatal("failed to install TapBridge for link: " + link.id);
    }

    LogInfo("[bind] " + inst.id + " " + inst.tapName, rt.verbose);

    rt.dynamicLinks.push_back(lr);
  }

  if (rt.corePortDevices.GetN() == 0)
  {
    Fatal("no core-side devices collected for bridge");
  }

  if (rt.config.globals.Ns3PairwiseImpairment())
  {
    BuildPairwiseLinks(rt);
    InstallPairwiseSwitch(rt);
  }
  else
  {
    BridgeHelper bridge;
    NetDeviceContainer bridgeDevs = bridge.Install(rt.coreNode, rt.corePortDevices);

    if (bridgeDevs.GetN() != 1)
    {
      Fatal("failed to install core BridgeNetDevice");
    }

    rt.coreBridge = DynamicCast<BridgeNetDevice>(bridgeDevs.Get(0));
    if (rt.coreBridge == nullptr)
    {
      Fatal("failed to cast installed bridge device");
    }

    LogInfo("[build] core bridge installed with " +
                std::to_string(rt.corePortDevices.GetN()) + " ports",
            rt.verbose);
  }
}

void
SetWifiEndpointMacAddress(const Ptr<NetDevice> &device, const InstanceSpec &inst)
{
  Ptr<WifiNetDevice> wifiDevice = DynamicCast<WifiNetDevice>(device);
  if (wifiDevice == nullptr)
  {
    Fatal("Wi-Fi endpoint device is not a WifiNetDevice: " + inst.id);
  }

  Ptr<WifiMac> wifiMac = wifiDevice->GetMac();
  if (wifiMac == nullptr)
  {
    Fatal("Wi-Fi endpoint device missing WifiMac: " + inst.id);
  }

  const Mac48Address endpointMac(inst.endpointMacAddress.c_str());
  Ptr<UcsTapBridgeAdhocWifiMac> lockedMac = DynamicCast<UcsTapBridgeAdhocWifiMac>(wifiMac);
  if (lockedMac != nullptr)
  {
    lockedMac->LockAddress(endpointMac);
  }
  else
  {
    device->SetAddress(endpointMac);
    wifiMac->SetAddress(endpointMac);
    for (uint8_t linkId : wifiMac->GetLinkIds())
    {
      Ptr<FrameExchangeManager> fem = wifiMac->GetFrameExchangeManager(linkId);
      if (fem == nullptr)
      {
        Fatal("Wi-Fi endpoint missing FrameExchangeManager: " + inst.id);
      }
      fem->SetAddress(endpointMac);
    }
  }

  if (!wifiMac->GetLinkIdByAddress(endpointMac).has_value())
  {
    Fatal("failed to synchronize Wi-Fi MAC/link address for endpoint: " + inst.id);
  }
}

static WifiEndpointStats *
LookupWifiEndpointStats(const std::string &endpointId)
{
  if (g_runtime == nullptr)
  {
    return nullptr;
  }
  auto it = g_runtime->wifiEndpointStats.find(endpointId);
  if (it == g_runtime->wifiEndpointStats.end())
  {
    return nullptr;
  }
  return &it->second;
}

static uint32_t
PacketSize(const Ptr<const Packet> &packet)
{
  return packet == nullptr ? 0 : packet->GetSize();
}

static bool
IsDataMpdu(const Ptr<const WifiMpdu> &mpdu)
{
  return mpdu != nullptr && mpdu->GetHeader().IsData();
}

static std::string
WifiMacDropReasonName(WifiMacDropReason reason)
{
  switch (reason)
  {
  case WIFI_MAC_DROP_FAILED_ENQUEUE:
    return "failed_enqueue";
  case WIFI_MAC_DROP_EXPIRED_LIFETIME:
    return "expired_lifetime";
  case WIFI_MAC_DROP_REACHED_RETRY_LIMIT:
    return "reached_retry_limit";
  case WIFI_MAC_DROP_QOS_OLD_PACKET:
    return "qos_old_packet";
  default:
    return "unknown";
  }
}

static void
OnWifiMacTx(std::string endpointId, Ptr<const Packet> packet)
{
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->macTxPackets;
    stats->macTxBytes += PacketSize(packet);
  }
}

static void
OnWifiMacRx(std::string endpointId, Ptr<const Packet> packet)
{
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->macRxPackets;
    stats->macRxBytes += PacketSize(packet);
  }
}

static void
OnWifiMacPromiscRx(std::string endpointId, Ptr<const Packet> packet)
{
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->macPromiscRxPackets;
    stats->macPromiscRxBytes += PacketSize(packet);
  }
}

static void
OnWifiMacTxDrop(std::string endpointId, Ptr<const Packet> packet)
{
  (void)packet;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->macTxDropPackets;
  }
}

static void
OnWifiMacRxDrop(std::string endpointId, Ptr<const Packet> packet)
{
  (void)packet;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->macRxDropPackets;
  }
}

static void
OnWifiPhyTxBegin(std::string endpointId, Ptr<const Packet> packet, double txPowerW)
{
  (void)txPowerW;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->phyTxBeginPackets;
    stats->phyTxBeginBytes += PacketSize(packet);
  }
}

static void
OnWifiPhyTxEnd(std::string endpointId, Ptr<const Packet> packet)
{
  (void)packet;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->phyTxEndPackets;
  }
}

static void
OnWifiPhyTxDrop(std::string endpointId, Ptr<const Packet> packet)
{
  (void)packet;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->phyTxDropPackets;
  }
}

static void
OnWifiPhyRxBegin(std::string endpointId,
                 Ptr<const Packet> packet,
                 RxPowerWattPerChannelBand rxPowersW)
{
  (void)rxPowersW;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->phyRxBeginPackets;
    stats->phyRxBeginBytes += PacketSize(packet);
  }
}

static void
OnWifiPhyRxEnd(std::string endpointId, Ptr<const Packet> packet)
{
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->phyRxEndPackets;
    stats->phyRxEndBytes += PacketSize(packet);
  }
}

static void
OnWifiPhyRxDrop(std::string endpointId,
                Ptr<const Packet> packet,
                WifiPhyRxfailureReason reason)
{
  (void)packet;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->phyRxDropPackets;
    stats->lastPhyRxDropReason = static_cast<uint32_t>(reason);
  }
}

static void
OnWifiAckedMpdu(std::string endpointId, Ptr<const WifiMpdu> mpdu)
{
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->ackedMpdu;
    if (mpdu != nullptr)
    {
      stats->retryCountTotal += mpdu->GetRetryCount();
    }
  }
}

static void
OnWifiNackedMpdu(std::string endpointId, Ptr<const WifiMpdu> mpdu)
{
  (void)mpdu;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->nackedMpdu;
  }
}

static void
OnWifiDroppedMpdu(std::string endpointId,
                  WifiMacDropReason reason,
                  Ptr<const WifiMpdu> mpdu)
{
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->droppedMpdu;
    stats->lastMacDropReason = WifiMacDropReasonName(reason);
    if (mpdu != nullptr)
    {
      stats->retryCountTotal += mpdu->GetRetryCount();
    }
    if (reason == WIFI_MAC_DROP_REACHED_RETRY_LIMIT)
    {
      ++stats->retryLimitDrops;
      if (IsDataMpdu(mpdu))
      {
        ++stats->finalDataFailed;
      }
    }
  }
}

static void
OnWifiMpduResponseTimeout(std::string endpointId,
                          uint8_t reason,
                          Ptr<const WifiMpdu> mpdu,
                          const WifiTxVector &txVector)
{
  (void)mpdu;
  (void)txVector;
  if (auto *stats = LookupWifiEndpointStats(endpointId))
  {
    ++stats->mpduResponseTimeouts;
    stats->lastResponseTimeoutReason = reason;
  }
}

static void
ConnectWifiTraceOrFatal(const Ptr<Object> &object,
                        const std::string &traceName,
                        const CallbackBase &callback,
                        const std::string &endpointId)
{
  if (object == nullptr || !object->TraceConnectWithoutContext(traceName, callback))
  {
    Fatal("failed to connect Wi-Fi trace " + traceName + " for endpoint: " +
          endpointId);
  }
}

void
RegisterWifiTraceSinks(TopologyRuntime &rt,
                       const std::string &endpointId,
                       const Ptr<NetDevice> &device)
{
  rt.wifiEndpointStats.emplace(endpointId, WifiEndpointStats{});

  Ptr<WifiNetDevice> wifiDevice = DynamicCast<WifiNetDevice>(device);
  if (wifiDevice == nullptr)
  {
    Fatal("cannot register Wi-Fi traces on non-WifiNetDevice: " + endpointId);
  }
  Ptr<WifiMac> wifiMac = wifiDevice->GetMac();
  Ptr<WifiPhy> wifiPhy = wifiDevice->GetPhy();
  if (wifiMac == nullptr || wifiPhy == nullptr)
  {
    Fatal("cannot register Wi-Fi traces without MAC/PHY: " + endpointId);
  }

  ConnectWifiTraceOrFatal(wifiMac, "MacTx",
                          MakeBoundCallback(&OnWifiMacTx, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "MacRx",
                          MakeBoundCallback(&OnWifiMacRx, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "MacPromiscRx",
                          MakeBoundCallback(&OnWifiMacPromiscRx, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "MacTxDrop",
                          MakeBoundCallback(&OnWifiMacTxDrop, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "MacRxDrop",
                          MakeBoundCallback(&OnWifiMacRxDrop, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "AckedMpdu",
                          MakeBoundCallback(&OnWifiAckedMpdu, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "NAckedMpdu",
                          MakeBoundCallback(&OnWifiNackedMpdu, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "DroppedMpdu",
                          MakeBoundCallback(&OnWifiDroppedMpdu, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiMac, "MpduResponseTimeout",
                          MakeBoundCallback(&OnWifiMpduResponseTimeout,
                                            endpointId),
                          endpointId);

  ConnectWifiTraceOrFatal(wifiPhy, "PhyTxBegin",
                          MakeBoundCallback(&OnWifiPhyTxBegin, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiPhy, "PhyTxEnd",
                          MakeBoundCallback(&OnWifiPhyTxEnd, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiPhy, "PhyTxDrop",
                          MakeBoundCallback(&OnWifiPhyTxDrop, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiPhy, "PhyRxBegin",
                          MakeBoundCallback(&OnWifiPhyRxBegin, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiPhy, "PhyRxEnd",
                          MakeBoundCallback(&OnWifiPhyRxEnd, endpointId),
                          endpointId);
  ConnectWifiTraceOrFatal(wifiPhy, "PhyRxDrop",
                          MakeBoundCallback(&OnWifiPhyRxDrop, endpointId),
                          endpointId);
}

void
CreateWifiAdhocFabric(TopologyRuntime &rt)
{
  const auto &cfg = rt.config;
  const auto &sim = cfg.linkSimulation;
  if (cfg.instances.empty())
  {
    Fatal("cannot create Wi-Fi fabric without instances");
  }

  rt.wifiNodes.Create(cfg.instances.size());

  Ptr<ListPositionAllocator> positions = CreateObject<ListPositionAllocator>();
  for (const auto &inst : cfg.instances)
  {
    positions->Add(EndpointFallbackPosition(cfg, inst.id));
  }

  MobilityHelper mobility;
  mobility.SetPositionAllocator(positions);
  mobility.SetMobilityModel("ns3::ConstantPositionMobilityModel");
  mobility.Install(rt.wifiNodes);

  for (uint32_t i = 0; i < cfg.instances.size(); ++i)
  {
    const auto &inst = cfg.instances.at(i);
    Ptr<Node> node = rt.wifiNodes.Get(i);
    Ptr<ConstantPositionMobilityModel> nodeMobility =
        node->GetObject<ConstantPositionMobilityModel>();
    if (nodeMobility == nullptr)
    {
      Fatal("failed to install endpoint mobility for Wi-Fi endpoint: " + inst.id);
    }
    rt.wifiEndpointIndex.emplace(inst.id, i);
    rt.endpointMobility[inst.id] = nodeMobility;
  }

  rt.wifiLossModel = CreateObject<MatrixPropagationLossModel>();
  rt.wifiLossModel->SetDefaultLoss(300.0);
  rt.wifiChannel = CreateObject<YansWifiChannel>();
  rt.wifiChannel->SetPropagationLossModel(rt.wifiLossModel);
  rt.wifiChannel->SetPropagationDelayModel(CreateObject<ConstantSpeedPropagationDelayModel>());

  WifiHelper wifi;
  wifi.SetStandard(ResolveWifiStandard(sim.wifiStandard));
  if (sim.wifiRateManager == "ns3::ConstantRateWifiManager")
  {
    wifi.SetRemoteStationManager(sim.wifiRateManager,
                                 "DataMode",
                                 StringValue(sim.wifiDataMode),
                                 "ControlMode",
                                 StringValue(sim.wifiControlMode));
  }
  else
  {
    wifi.SetRemoteStationManager(sim.wifiRateManager);
  }

  WifiMacHelper wifiMac;
  wifiMac.SetType("ns3::UcsTapBridgeAdhocWifiMac");

  YansWifiPhyHelper wifiPhy;
  wifiPhy.SetChannel(rt.wifiChannel);
  if (!sim.wifiChannelSettings.empty())
  {
    wifiPhy.Set("ChannelSettings", StringValue(sim.wifiChannelSettings));
  }
  wifiPhy.Set("TxPowerStart", DoubleValue(sim.txPowerDbm));
  wifiPhy.Set("TxPowerEnd", DoubleValue(sim.txPowerDbm));
  wifiPhy.Set("RxSensitivity", DoubleValue(sim.WifiRxSensitivityDbm()));
  wifiPhy.Set("CcaEdThreshold", DoubleValue(sim.wifiCcaEdThresholdDbm));

  rt.wifiDevices = wifi.Install(wifiPhy, wifiMac, rt.wifiNodes);
  if (rt.wifiDevices.GetN() != cfg.instances.size())
  {
    Fatal("failed to install one Wi-Fi device per endpoint");
  }

  for (uint32_t i = 0; i < cfg.instances.size(); ++i)
  {
    const auto &inst = cfg.instances.at(i);
    if (inst.tapName.empty())
    {
      Fatal("Wi-Fi endpoint missing tap_name: " + inst.id);
    }

    Ptr<NetDevice> device = rt.wifiDevices.Get(i);
    SetWifiEndpointMacAddress(device, inst);
    rt.wifiEndpointDevice.emplace(inst.id, device);
    RegisterWifiTraceSinks(rt, inst.id, device);

    TapBridgeHelper tap;
    tap.SetAttribute("Mode", StringValue(sim.wifiTapBridgeMode));
    tap.SetAttribute("DeviceName", StringValue(inst.tapName));
    Ptr<NetDevice> tapDev = tap.Install(rt.wifiNodes.Get(i), device);
    Ptr<TapBridge> tapBridge = DynamicCast<TapBridge>(tapDev);
    if (tapBridge == nullptr)
    {
      Fatal("failed to install Wi-Fi TapBridge for endpoint: " + inst.id);
    }
    rt.wifiTapBridge.emplace(inst.id, tapBridge);

    LogInfo("[bind] " + inst.id + " " + inst.tapName + " wifi_mode=ad_hoc tap_mode=" +
                sim.wifiTapBridgeMode + " endpoint_mac=" + inst.endpointMacAddress,
            rt.verbose);
  }

  std::ostringstream oss;
  oss << "[build] ns-3 Wi-Fi ad-hoc fabric installed"
      << " endpoints=" << cfg.instances.size()
      << " pair_links=" << rt.pairLinks.size()
      << " drop_authority=ns3_wifi_phy_mac"
      << " propagation=matrix_large_small_fading_v1"
      << " standard=" << sim.wifiStandard
      << " mac=" << sim.wifiMacType
      << " rate_manager=" << sim.wifiRateManager
      << " tap_bridge_mac_sync=ns3::UcsTapBridgeAdhocWifiMac"
      << " data_mode="
      << (sim.wifiRateManager == "ns3::ConstantRateWifiManager" ? sim.wifiDataMode : "adaptive")
      << " control_mode="
      << (sim.wifiRateManager == "ns3::ConstantRateWifiManager" ? sim.wifiControlMode : "adaptive")
      << " channel_settings="
      << (sim.wifiChannelSettings.empty() ? "default" : sim.wifiChannelSettings)
      << " tx_power_dbm=" << sim.txPowerDbm
      << " wifi_rx_sensitivity_dbm=" << sim.WifiRxSensitivityDbm()
      << " rx_loss_full_dbm_compat=" << sim.rxLossFullDbm
      << " cca_ed_threshold_dbm=" << sim.wifiCcaEdThresholdDbm;
  LogInfo(oss.str(), true);
}

void
RegisterCorePort(TopologyRuntime &rt, const std::string &endpointId,
                 const Ptr<NetDevice> &device)
{
  if (endpointId.empty() || device == nullptr)
  {
    Fatal("cannot register empty pairwise switch port");
  }

  for (const auto &port : rt.corePorts)
  {
    if (port.endpointId == endpointId)
    {
      Fatal("duplicate pairwise switch endpoint port: " + endpointId);
    }
  }

  CorePortRuntime port;
  port.endpointId = endpointId;
  port.device = device;
  const uint32_t portIndex = static_cast<uint32_t>(rt.corePorts.size());
  rt.corePorts.push_back(port);

  const auto instIt = rt.instanceMap.find(endpointId);
  if (instIt != rt.instanceMap.end() && !instIt->second.endpointMacAddress.empty())
  {
    rt.learnedMacToPort[NormalizeMacAddress(instIt->second.endpointMacAddress)] =
        portIndex;
  }
}

void
BuildPairwiseLinks(TopologyRuntime &rt)
{
  for (const auto &link : GetEnabledPairwiseLinks(rt.config))
  {
    PairLinkRuntime pl;
    pl.spec = link;
    pl.currentDelay = ParseTimeOrDefault(link.baseDelay, MilliSeconds(2));

    pl.jitterRng = CreateObject<UniformRandomVariable>();
    pl.jitterRng->SetAttribute("Min", DoubleValue(-1.0));
    pl.jitterRng->SetAttribute("Max", DoubleValue(1.0));

    pl.errorRng = CreateObject<UniformRandomVariable>();
    pl.errorRng->SetAttribute("Min", DoubleValue(0.0));
    pl.errorRng->SetAttribute("Max", DoubleValue(1.0));

    pl.retryJitterRng = CreateObject<UniformRandomVariable>();
    pl.retryJitterRng->SetAttribute("Min", DoubleValue(0.0));
    pl.retryJitterRng->SetAttribute("Max", DoubleValue(1.0));

    pl.backoffRng = CreateObject<UniformRandomVariable>();
    pl.backoffRng->SetAttribute("Min", DoubleValue(0.0));
    pl.backoffRng->SetAttribute("Max", DoubleValue(1.0));

    pl.packetErrorModel = CreateObject<RateErrorModel>();
    pl.packetErrorModel->SetUnit(RateErrorModel::ERROR_UNIT_PACKET);
    pl.packetErrorModel->SetRate(0.0);

    const std::string key = EndpointPairKey(link.src, link.dst);
    if (rt.pairLinkIndexByEndpointKey.find(key) != rt.pairLinkIndexByEndpointKey.end())
    {
      Fatal("duplicate pairwise runtime link endpoint pair: " + link.id);
    }

    rt.pairLinkIndexByEndpointKey.emplace(key, rt.pairLinks.size());
    rt.pairLinks.push_back(pl);
  }

  const std::string role =
      rt.config.globals.Ns3WifiAdhoc() ? "wifi matrix endpoint-pair links"
                                       : "pairwise impairment links";
  LogInfo("[build] " + role + "=" + std::to_string(rt.pairLinks.size()),
          rt.verbose);
}

void
InstallPairwiseSwitch(TopologyRuntime &rt)
{
  if (rt.corePorts.empty())
  {
    Fatal("cannot install pairwise switch without core ports");
  }

  for (const auto &port : rt.corePorts)
  {
    port.device->SetPromiscReceiveCallback(MakeCallback(&CorePromiscReceive));
  }

  LogInfo("[build] ns-3 pairwise L2 switch installed with " +
              std::to_string(rt.corePorts.size()) + " ports",
          rt.verbose);
}

void
EnablePcapIfNeeded(TopologyRuntime &rt)
{
  if (!rt.pcapEnabled)
  {
    return;
  }

  Fatal("pcap capture requested after validation, but this checkpoint does not "
        "implement pcap capture");
}

std::optional<Time>
ParseTimeStrictValue(const std::string &value)
{
  try
  {
    const std::string v = Trim(value);
    if (v.empty())
    {
      return std::nullopt;
    }

    double number = 0.0;
    double nanos = 0.0;

    if (EndsWith(v, "ns"))
    {
      number = ParseDoublePrefix(v, "ns");
      nanos = number;
    }
    else if (EndsWith(v, "us"))
    {
      number = ParseDoublePrefix(v, "us");
      nanos = number * 1e3;
    }
    else if (EndsWith(v, "ms"))
    {
      number = ParseDoublePrefix(v, "ms");
      nanos = number * 1e6;
    }
    else if (EndsWith(v, "s"))
    {
      number = ParseDoublePrefix(v, "s");
      nanos = number * 1e9;
    }
    else
    {
      return std::nullopt;
    }

    if (!std::isfinite(number) || !std::isfinite(nanos) || nanos < 0.0)
    {
      return std::nullopt;
    }

    const int64_t ns = static_cast<int64_t>(std::llround(nanos));
    return NanoSeconds(ns);
  }
  catch (const std::exception &)
  {
    return std::nullopt;
  }
}

Time
ParseTimeOrDefault(const std::string &value, const Time &fallback)
{
  const auto parsed = ParseTimeStrictValue(value);
  if (parsed.has_value())
  {
    return *parsed;
  }
  return fallback;
}

DataRate
ParseDataRateOrDefault(const std::string &value, const std::string &fallback)
{
  try
  {
    const std::string v = Trim(value);
    if (!v.empty())
    {
      return DataRate(v);
    }
  }
  catch (const std::exception &)
  {
  }

  return DataRate(fallback);
}

Vector
RequireVector3Array(const json &obj, const std::string &name, const std::string &context)
{
  if (!obj.contains(name))
  {
    Fatal(context + " missing required vector field: " + name);
  }
  const json &arr = obj.at(name);
  if (!arr.is_array() || arr.size() != 3)
  {
    Fatal(context + "." + name + " must be an array of three numbers");
  }
  for (const auto &v : arr)
  {
    if (!v.is_number())
    {
      Fatal(context + "." + name + " must contain only numbers");
    }
  }

  return Vector(arr.at(0).get<double>(), arr.at(1).get<double>(), arr.at(2).get<double>());
}

Vector
OptionalVectorObjectField(const json &obj, const std::string &name, const Vector &fallback)
{
  if (!obj.contains(name))
  {
    return fallback;
  }
  const json &v = obj.at(name);
  if (!v.is_object())
  {
    Fatal("field is not an object: " + name);
  }
  return Vector(OptionalNumberField(v, "x", fallback.x),
                OptionalNumberField(v, "y", fallback.y),
                OptionalNumberField(v, "z", fallback.z));
}

Building::BuildingType_t
ParseBuildingType(const std::string &value)
{
  if (value == "Residential")
  {
    return Building::Residential;
  }
  if (value == "Office")
  {
    return Building::Office;
  }
  if (value == "Commercial")
  {
    return Building::Commercial;
  }
  Fatal("unsupported building_type: " + value);
  return Building::Commercial;
}

Building::ExtWallsType_t
ParseExtWallsType(const std::string &value)
{
  if (value == "Wood")
  {
    return Building::Wood;
  }
  if (value == "ConcreteWithWindows")
  {
    return Building::ConcreteWithWindows;
  }
  if (value == "ConcreteWithoutWindows")
  {
    return Building::ConcreteWithoutWindows;
  }
  if (value == "StoneBlocks")
  {
    return Building::StoneBlocks;
  }
  Fatal("unsupported ext_walls_type: " + value);
  return Building::ConcreteWithWindows;
}

Ptr<ChannelConditionModel>
CreateChannelConditionModel(const std::string &typeName)
{
  TypeId tid;
  if (!TypeId::LookupByNameFailSafe(typeName, &tid))
  {
    Fatal("unknown channel condition model TypeId: " + typeName);
  }

  ObjectFactory factory;
  factory.SetTypeId(tid);
  Ptr<ChannelConditionModel> model = factory.Create<ChannelConditionModel>();
  if (model == nullptr)
  {
    Fatal("TypeId is not a ChannelConditionModel: " + typeName);
  }
  return model;
}

Ptr<PropagationLossModel>
CreatePropagationLossModel(const std::string &typeName)
{
  TypeId tid;
  if (!TypeId::LookupByNameFailSafe(typeName, &tid))
  {
    Fatal("unknown propagation loss model TypeId: " + typeName);
  }

  ObjectFactory factory;
  factory.SetTypeId(tid);
  Ptr<PropagationLossModel> model = factory.Create<PropagationLossModel>();
  if (model == nullptr)
  {
    Fatal("TypeId is not a PropagationLossModel: " + typeName);
  }
  return model;
}

double
UpdateShadowFadingDb(TopologyRuntime &rt, FadingRuntimeState &state,
                     double distanceM, double relativeSpeedMps)
{
  const auto &sim = rt.config.linkSimulation;
  if (!sim.shadowFadingEnabled || sim.shadowFadingStddevDb == 0.0)
  {
    state.shadowInitialized = true;
    state.shadowDb = 0.0;
    state.lastDistanceM = distanceM;
    return 0.0;
  }

  const double sigmaDb = sim.shadowFadingStddevDb;
  const double z = (rt.shadowNormalRng != nullptr) ? rt.shadowNormalRng->GetValue() : 0.0;
  if (!state.shadowInitialized)
  {
    state.shadowInitialized = true;
    state.shadowDb = z * sigmaDb;
    state.lastDistanceM = distanceM;
    return state.shadowDb;
  }

  const double tickSec = ParseTimeOrDefault(rt.config.globals.tick, MilliSeconds(200)).GetSeconds();
  const double distanceDelta = std::abs(distanceM - state.lastDistanceM);
  const double speedDelta = std::abs(relativeSpeedMps) * tickSec;
  const double displacementM = std::max(distanceDelta, speedDelta);
  const double correlation =
      std::exp(-displacementM / sim.shadowFadingCorrelationDistanceM);
  const double innovationScale = std::sqrt(std::max(0.0, 1.0 - correlation * correlation));

  state.shadowDb = correlation * state.shadowDb + innovationScale * z * sigmaDb;
  state.lastDistanceM = distanceM;
  return state.shadowDb;
}

double
SegmentAabbIntersectionLengthM(const Vector &a, const Vector &b,
                               const BuildingObstacleSpec &obs,
                               double expansionM = 0.0)
{
  const double expansion = std::max(0.0, expansionM);
  const Vector half(obs.size.x / 2.0 + expansion,
                    obs.size.y / 2.0 + expansion,
                    obs.size.z / 2.0 + expansion);
  const Vector minV(obs.center.x - half.x, obs.center.y - half.y, obs.center.z - half.z);
  const Vector maxV(obs.center.x + half.x, obs.center.y + half.y, obs.center.z + half.z);
  const Vector d(b.x - a.x, b.y - a.y, b.z - a.z);

  double tMin = 0.0;
  double tMax = 1.0;
  auto clipAxis = [&](double p, double dp, double lo, double hi) -> bool {
    constexpr double kEps = 1e-9;
    if (std::abs(dp) < kEps)
    {
      return p >= lo && p <= hi;
    }
    double t1 = (lo - p) / dp;
    double t2 = (hi - p) / dp;
    if (t1 > t2)
    {
      std::swap(t1, t2);
    }
    tMin = std::max(tMin, t1);
    tMax = std::min(tMax, t2);
    return tMin <= tMax;
  };

  if (!clipAxis(a.x, d.x, minV.x, maxV.x) ||
      !clipAxis(a.y, d.y, minV.y, maxV.y) ||
      !clipAxis(a.z, d.z, minV.z, maxV.z))
  {
    return 0.0;
  }

  const double segmentLength =
      std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
  if (segmentLength <= 0.0)
  {
    return 0.0;
  }
  return std::max(0.0, (tMax - tMin) * segmentLength);
}

double
SmoothStep01(double x)
{
  const double t = std::clamp(x, 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

struct ObstructionLossResult
{
  double lossDb{0.0};
  bool coreHit{false};
  bool diffractionHit{false};
};

ObstructionLossResult
ComputeObstructionLoss(const LinkSimulationConfig &sim,
                       const LinkMetricsSample &sample)
{
  if (!sim.obstructionLossEnabled || !sample.hasPositions || sim.obstacles.empty())
  {
    return {};
  }

  if (sim.obstructionBaseLossDb <= 0.0 &&
      sim.obstructionLossPerHitDb <= 0.0 &&
      sim.obstructionLossPerMeterDb <= 0.0 &&
      sim.obstructionDiffractionLossDb <= 0.0)
  {
    return {};
  }

  ObstructionLossResult result;
  double rawLossDb = 0.0;
  for (const auto &obs : sim.obstacles)
  {
    const double coreLengthM =
        SegmentAabbIntersectionLengthM(sample.srcPosition, sample.dstPosition, obs);
    if (coreLengthM >= sim.obstructionMinIntersectionM)
    {
      result.coreHit = true;
      const double penetrationM =
          std::max(0.0, coreLengthM - sim.obstructionMinIntersectionM);
      double rampWeight = 1.0;
      if (sim.obstructionEdgeRampM > 0.0)
      {
        rampWeight = SmoothStep01(penetrationM / sim.obstructionEdgeRampM);
      }

      // Without a ramp, this keeps the legacy behavior. With a ramp, the
      // per-hit penalty no longer appears as a full dB step as soon as the
      // segment grazes an AABB; it grows gradually as penetration increases.
      const double meterLengthM =
          (sim.obstructionEdgeRampM > 0.0) ? penetrationM : coreLengthM;
      rawLossDb +=
          sim.obstructionBaseLossDb +
          rampWeight * sim.obstructionLossPerHitDb +
          meterLengthM * sim.obstructionLossPerMeterDb;
      continue;
    }

    if (sim.obstructionDiffractionMarginM > 0.0 &&
        sim.obstructionDiffractionLossDb > 0.0)
    {
      const double shellLengthM =
          SegmentAabbIntersectionLengthM(sample.srcPosition, sample.dstPosition, obs,
                                         sim.obstructionDiffractionMarginM);
      if (shellLengthM >= sim.obstructionMinIntersectionM)
      {
        result.diffractionHit = true;
        const double shellPenetrationM =
            std::max(0.0, shellLengthM - sim.obstructionMinIntersectionM);
        const double shellWeight =
            SmoothStep01(shellPenetrationM / sim.obstructionDiffractionMarginM);
        rawLossDb += shellWeight * sim.obstructionDiffractionLossDb;
      }
    }
  }

  result.lossDb = std::min(sim.obstructionLossMaxDb, std::max(0.0, rawLossDb));
  return result;
}

double
UpdateObstructionLossDb(const LinkSimulationConfig &sim,
                        FadingRuntimeState &state,
                        const LinkMetricsSample &sample)
{
  const ObstructionLossResult obstruction = ComputeObstructionLoss(sim, sample);
  const double rawLossDb = obstruction.lossDb;
  state.obstructionRawLossDb = rawLossDb;
  if (!sim.obstructionLossEnabled || !sample.hasPositions)
  {
    state.channelState = "UNKNOWN";
  }
  else
  {
    if (obstruction.coreHit)
    {
      state.channelState = "NLOS";
    }
    else if (obstruction.diffractionHit)
    {
      state.channelState = "DIFFRACTION";
    }
    else
    {
      state.channelState = "LOS";
    }
  }

  const double nowS = Simulator::Now().GetSeconds();
  if (!state.obstructionInitialized || sim.obstructionSmoothingTauS <= 0.0)
  {
    state.obstructionInitialized = true;
    state.obstructionLossDb = rawLossDb;
    state.obstructionLastUpdateS = nowS;
    return state.obstructionLossDb;
  }

  const double elapsedS = std::max(0.0, nowS - state.obstructionLastUpdateS);
  const double alpha =
      1.0 - std::exp(-elapsedS / std::max(1.0e-6, sim.obstructionSmoothingTauS));
  state.obstructionLossDb += alpha * (rawLossDb - state.obstructionLossDb);
  state.obstructionLastUpdateS = nowS;
  return state.obstructionLossDb;
}

double
UpdateMultipathFadingDeltaDb(TopologyRuntime &rt, FadingRuntimeState &state,
                             double baseRxPowerDbm, double distanceM,
                             double relativeSpeedMps)
{
  const auto &sim = rt.config.linkSimulation;
  state.multipathResampled = false;
  if (!sim.multipathFadingEnabled || rt.largeSmallMultipathModel == nullptr)
  {
    const double nowS = Simulator::Now().GetSeconds();
    state.multipathInitialized = true;
    state.multipathDeltaDb = 0.0;
    state.multipathTargetDeltaDb = 0.0;
    state.multipathLastDistanceM = distanceM;
    state.multipathLastUpdateS = nowS;
    state.multipathLastSmoothUpdateS = nowS;
    return 0.0;
  }

  const double nowS = Simulator::Now().GetSeconds();
  const bool moving =
      std::abs(relativeSpeedMps) >= sim.multipathMinRelativeSpeedMps;

  if (!state.multipathInitialized)
  {
    const double sampledRxPowerDbm =
        rt.largeSmallMultipathModel->CalcRxPower(baseRxPowerDbm,
                                                 rt.fadingSrcMobility,
                                                 rt.fadingDstMobility);
    state.multipathInitialized = true;
    state.multipathTargetDeltaDb =
        std::clamp(sampledRxPowerDbm - baseRxPowerDbm,
                   -sim.multipathMaxLossDb,
                   sim.multipathMaxGainDb);
    state.multipathDeltaDb = state.multipathTargetDeltaDb;
    state.multipathLastDistanceM = distanceM;
    state.multipathLastUpdateS = nowS;
    state.multipathLastSmoothUpdateS = nowS;
    state.multipathResampled = true;
    return state.multipathDeltaDb;
  }

  const double distanceDelta = std::abs(distanceM - state.multipathLastDistanceM);
  const double elapsedS = nowS - state.multipathLastUpdateS;
  const bool shouldResample =
      moving && (distanceDelta >= sim.multipathCoherenceDistanceM ||
                 elapsedS >= sim.multipathCoherenceTimeS);
  if (shouldResample)
  {
    const double sampledRxPowerDbm =
        rt.largeSmallMultipathModel->CalcRxPower(baseRxPowerDbm,
                                                 rt.fadingSrcMobility,
                                                 rt.fadingDstMobility);
    state.multipathTargetDeltaDb =
        std::clamp(sampledRxPowerDbm - baseRxPowerDbm,
                   -sim.multipathMaxLossDb,
                   sim.multipathMaxGainDb);
    state.multipathLastDistanceM = distanceM;
    state.multipathLastUpdateS = nowS;
    state.multipathResampled = true;
  }

  if (sim.multipathSmoothingTauS <= 0.0)
  {
    state.multipathDeltaDb = state.multipathTargetDeltaDb;
    state.multipathLastSmoothUpdateS = nowS;
    return state.multipathDeltaDb;
  }

  const double smoothElapsedS =
      std::max(0.0, nowS - state.multipathLastSmoothUpdateS);
  const double alpha =
      1.0 - std::exp(-smoothElapsedS / std::max(1.0e-6, sim.multipathSmoothingTauS));
  state.multipathDeltaDb +=
      alpha * (state.multipathTargetDeltaDb - state.multipathDeltaDb);
  state.multipathLastSmoothUpdateS = nowS;
  return state.multipathDeltaDb;
}

double
ComputeLargeSmallFadingRxPower(TopologyRuntime &rt, FadingRuntimeState &state,
                               const LinkMetricsSample &sample)
{
  const auto &sim = rt.config.linkSimulation;
  if (rt.largeSmallPathLossModel == nullptr ||
      rt.fadingSrcMobility == nullptr ||
      rt.fadingDstMobility == nullptr)
  {
    return std::numeric_limits<double>::quiet_NaN();
  }

  const double distanceM = std::max(0.001, sample.dist);
  rt.fadingSrcMobility->SetPosition(Vector(0.0, 0.0, 0.0));
  rt.fadingDstMobility->SetPosition(Vector(distanceM, 0.0, 0.0));

  double rxPowerDbm =
      rt.largeSmallPathLossModel->CalcRxPower(sim.txPowerDbm,
                                              rt.fadingSrcMobility,
                                              rt.fadingDstMobility);
  state.pathLossDb = sim.txPowerDbm - rxPowerDbm;

  const double shadowDb = UpdateShadowFadingDb(rt, state, distanceM, sample.speed);
  rxPowerDbm -= shadowDb;

  const double obstructionLossDb = UpdateObstructionLossDb(sim, state, sample);
  rxPowerDbm -= obstructionLossDb;

  const double multipathDeltaDb =
      UpdateMultipathFadingDeltaDb(rt, state, rxPowerDbm, distanceM, sample.speed);
  rxPowerDbm += multipathDeltaDb;

  if (sim.dopplerFadingEnabled && rt.largeSmallDopplerModel != nullptr &&
      std::abs(sample.speed) >= sim.dopplerMinRelativeSpeedMps)
  {
    rxPowerDbm =
        rt.largeSmallDopplerModel->CalcRxPower(rxPowerDbm,
                                               rt.fadingSrcMobility,
                                               rt.fadingDstMobility);
  }

  return rxPowerDbm;
}

double
ComputeWifiMatrixRxPower(TopologyRuntime &rt, FadingRuntimeState &state,
                         const LinkSpec &spec, const LinkMetricsSample &sample)
{
  (void)spec;
  const auto &sim = rt.config.linkSimulation;
  if (sim.LargeSmallFading())
  {
    return ComputeLargeSmallFadingRxPower(rt, state, sample);
  }

  const double distanceM = std::max(0.001, sample.dist);
  const double referenceDistanceM = std::max(0.001, sim.pathLossReferenceDistanceM);
  const double normalizedDistance = std::max(distanceM, referenceDistanceM);
  const double pathLossDb =
      sim.pathLossReferenceLossDb +
      10.0 * sim.pathLossExponent *
          std::log10(normalizedDistance / referenceDistanceM);
  state.pathLossDb = pathLossDb;
  state.shadowDb = 0.0;
  state.obstructionLossDb = 0.0;
  state.obstructionRawLossDb = 0.0;
  state.channelState = sample.hasPositions ? "LOS" : "UNKNOWN";
  state.multipathDeltaDb = 0.0;
  state.multipathResampled = false;
  return sim.txPowerDbm - pathLossDb;
}

Vector
EndpointFallbackPosition(const TopologyConfig &cfg, const std::string &endpointId)
{
  if (endpointId == cfg.globals.gsId)
  {
    return cfg.globals.gsPose;
  }

  for (const auto &inst : cfg.instances)
  {
    if (inst.id == endpointId)
    {
      return inst.hasSpawnPose ? inst.spawnPose : Vector(0.0, 0.0, 0.0);
    }
  }

  return Vector(0.0, 0.0, 0.0);
}

double
Distance3d(const Vector &a, const Vector &b)
{
  const double dx = a.x - b.x;
  const double dy = a.y - b.y;
  const double dz = a.z - b.z;
  return std::sqrt(dx * dx + dy * dy + dz * dz);
}

std::optional<double>
ReadSharedTime(const std::string &timeFile)
{
  std::ifstream ifs(timeFile);
  if (!ifs.good())
  {
    return std::nullopt;
  }

  double t = 0.0;
  if (!(ifs >> t))
  {
    return std::nullopt;
  }

  return t;
}

std::optional<LinkMetricsSample>
ReadLinkMetrics(const std::string &metricsFile)
{
  std::ifstream ifs(metricsFile);
  if (!ifs.good())
  {
    return std::nullopt;
  }

  LinkMetricsSample sample;
  if (!(ifs >> sample.speed >> sample.dist))
  {
    return std::nullopt;
  }

  double sx = 0.0;
  double sy = 0.0;
  double sz = 0.0;
  double dx = 0.0;
  double dy = 0.0;
  double dz = 0.0;
  if (ifs >> sx >> sy >> sz >> dx >> dy >> dz)
  {
    sample.hasPositions = true;
    sample.srcPosition = Vector(sx, sy, sz);
    sample.dstPosition = Vector(dx, dy, dz);

    int validFlag = 1;
    int modelSeenFlag = 1;
    if (ifs >> validFlag >> modelSeenFlag)
    {
      sample.valid = (validFlag != 0);
      sample.modelSeen = (modelSeenFlag != 0);
      // Fallback positions are useful for startup distance estimates, but they
      // should not trigger building/AABB obstruction losses.
      sample.hasPositions = sample.hasPositions && sample.valid && sample.modelSeen;
    }
  }

  return sample;
}

std::string
SanitizeForPath(const std::string &value)
{
  std::string out;
  out.reserve(value.size());
  for (unsigned char ch : value)
  {
    if (std::isalnum(ch) || ch == '_' || ch == '-' || ch == '.')
    {
      out.push_back(static_cast<char>(ch));
    }
    else
    {
      out.push_back('_');
    }
  }
  return out.empty() ? "default" : out;
}

std::string
SharedMetricsPath(const TopologyConfig &cfg)
{
  return "/dev/shm/ucs_mesh_metrics_" +
         SanitizeForPath(cfg.globals.scenarioId) + ".bin";
}

std::string
LinkStateSharedPath(const TopologyConfig &cfg)
{
  return "/dev/shm/ucs_mesh_link_state_" +
         SanitizeForPath(cfg.globals.scenarioId) + ".bin";
}

std::string
LinkStateHistoryPath(const TopologyConfig &cfg)
{
  return "/tmp/ucs_mesh_link_state_" +
         SanitizeForPath(cfg.globals.scenarioId) + ".history.log";
}

double
WallUnixSeconds()
{
  using Clock = std::chrono::system_clock;
  return std::chrono::duration<double>(Clock::now().time_since_epoch()).count();
}

void
CleanupSharedMetrics(TopologyRuntime &rt)
{
  auto &channel = rt.sharedMetrics;
  if (channel.data != nullptr && channel.size > 0)
  {
    ::munmap(const_cast<uint8_t *>(channel.data), channel.size);
  }
  if (channel.fd >= 0)
  {
    ::close(channel.fd);
  }

  channel.fd = -1;
  channel.data = nullptr;
  channel.size = 0;
  channel.snapshotValid = false;
  channel.samples.clear();
}

void
CleanupLinkStateChannel(TopologyRuntime &rt)
{
  auto &channel = rt.linkState;
  if (channel.data != nullptr && channel.size > 0)
  {
    ::munmap(channel.data, channel.size);
  }
  if (channel.fd >= 0)
  {
    ::close(channel.fd);
  }

  channel.fd = -1;
  channel.data = nullptr;
  channel.size = 0;
}

bool
EnsureSharedMetricsOpen(TopologyRuntime &rt)
{
  auto &channel = rt.sharedMetrics;
  if (channel.fd >= 0 && channel.data != nullptr)
  {
    return true;
  }

  if (channel.path.empty())
  {
    channel.path = SharedMetricsPath(rt.config);
  }

  const int fd = ::open(channel.path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0)
  {
    return false;
  }

  struct stat st
  {
  };
  if (::fstat(fd, &st) != 0 ||
      st.st_size < static_cast<off_t>(sizeof(SharedMetricsHeader)))
  {
    ::close(fd);
    return false;
  }

  void *mapping = ::mmap(nullptr,
                         static_cast<size_t>(st.st_size),
                         PROT_READ,
                         MAP_SHARED,
                         fd,
                         0);
  if (mapping == MAP_FAILED)
  {
    ::close(fd);
    return false;
  }

  channel.fd = fd;
  channel.data = static_cast<const uint8_t *>(mapping);
  channel.size = static_cast<size_t>(st.st_size);
  if (!channel.loggedOpen)
  {
    LogInfo("[metrics] shared_metrics=" + channel.path, rt.verbose);
    channel.loggedOpen = true;
  }
  return true;
}

bool
RefreshSharedMetricsSnapshot(TopologyRuntime &rt)
{
  auto &channel = rt.sharedMetrics;
  const bool hadSnapshot = channel.snapshotValid;

  if (!EnsureSharedMetricsOpen(rt))
  {
    return hadSnapshot;
  }

  SharedMetricsHeader first{};
  std::memcpy(&first, channel.data, sizeof(first));
  if (std::memcmp(first.magic, kSharedMetricsMagic, sizeof(first.magic)) != 0 ||
      first.version != kSharedMetricsVersion ||
      (first.seq & 1U) != 0)
  {
    return hadSnapshot;
  }

  const size_t expectedSize = sizeof(SharedMetricsHeader) +
                              static_cast<size_t>(first.linkCount) *
                                  sizeof(SharedMetricsRecord);
  if (first.linkCount == 0 || expectedSize > channel.size)
  {
    CleanupSharedMetrics(rt);
    return false;
  }

  std::map<std::string, LinkMetricsSample> samples;
  const uint8_t *records = channel.data + sizeof(SharedMetricsHeader);
  for (uint32_t i = 0; i < first.linkCount; ++i)
  {
    SharedMetricsRecord record{};
    std::memcpy(&record, records + i * sizeof(SharedMetricsRecord), sizeof(record));

    size_t idLen = 0;
    while (idLen < kSharedMetricsLinkIdBytes && record.linkId[idLen] != '\0')
    {
      ++idLen;
    }
    if (idLen == 0)
    {
      continue;
    }

    LinkMetricsSample sample;
    sample.speed = record.values[0];
    sample.dist = record.values[1];
    sample.srcPosition = Vector(record.values[2], record.values[3], record.values[4]);
    sample.dstPosition = Vector(record.values[5], record.values[6], record.values[7]);
    sample.valid = (record.valid != 0);
    sample.modelSeen = (record.modelSeen != 0);
    sample.hasPositions = sample.valid && sample.modelSeen;
    samples.emplace(std::string(record.linkId, idLen), sample);
  }

  SharedMetricsHeader second{};
  std::memcpy(&second, channel.data, sizeof(second));
  if (std::memcmp(second.magic, kSharedMetricsMagic, sizeof(second.magic)) != 0 ||
      second.version != first.version ||
      second.linkCount != first.linkCount ||
      second.seq != first.seq ||
      (second.seq & 1U) != 0)
  {
    return hadSnapshot;
  }

  channel.samples = std::move(samples);
  channel.seq = second.seq;
  channel.simTime = second.simTime;
  channel.snapshotValid = true;
  return true;
}

bool
EnsureLinkStateChannelOpen(TopologyRuntime &rt)
{
  auto &channel = rt.linkState;
  if (channel.fd >= 0 && channel.data != nullptr)
  {
    return true;
  }

  if (channel.path.empty())
  {
    channel.path = LinkStateSharedPath(rt.config);
  }
  if (channel.historyPath.empty())
  {
    channel.historyPath = LinkStateHistoryPath(rt.config);
  }

  const size_t mappingSize = sizeof(LinkStateHeader) + kLinkStatePayloadBytes;
  const int fd = ::open(channel.path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0666);
  if (fd < 0)
  {
    if (!channel.warningLogged)
    {
      LogInfo("[link-state][W] open failed path=" + channel.path + " errno=" +
                  std::to_string(errno),
              rt.verbose);
      channel.warningLogged = true;
    }
    return false;
  }

  if (::ftruncate(fd, static_cast<off_t>(mappingSize)) != 0)
  {
    if (!channel.warningLogged)
    {
      LogInfo("[link-state][W] ftruncate failed path=" + channel.path + " errno=" +
                  std::to_string(errno),
              rt.verbose);
      channel.warningLogged = true;
    }
    ::close(fd);
    return false;
  }

  void *mapping = ::mmap(nullptr,
                         mappingSize,
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED,
                         fd,
                         0);
  if (mapping == MAP_FAILED)
  {
    if (!channel.warningLogged)
    {
      LogInfo("[link-state][W] mmap failed path=" + channel.path + " errno=" +
                  std::to_string(errno),
              rt.verbose);
      channel.warningLogged = true;
    }
    ::close(fd);
    return false;
  }

  channel.fd = fd;
  channel.data = static_cast<uint8_t *>(mapping);
  channel.size = mappingSize;
  if (!channel.loggedOpen)
  {
    LogInfo("[link-state] shared_state=" + channel.path +
                " history=" + channel.historyPath,
            rt.verbose);
    channel.loggedOpen = true;
  }
  return true;
}

std::string
BuildLinkStateSnapshot(double t, const TopologyRuntime &rt, uint32_t *lineCount)
{
  std::ostringstream oss;
  uint32_t count = 0;

  if (rt.config.globals.EndpointPairLinkImpairment() ||
      rt.config.globals.Ns3WifiAdhoc())
  {
    for (const auto &pl : rt.pairLinks)
    {
      oss << PairLinkStateLine(t, pl) << '\n';
      ++count;
    }
  }
  else
  {
    for (const auto &lr : rt.dynamicLinks)
    {
      oss << LinkStateLine(t, lr) << '\n';
      ++count;
    }
  }

  const double nowS = std::max(t, Simulator::Now().GetSeconds());
  for (const auto &[endpointId, stats] : rt.wifiEndpointStats)
  {
    oss << WifiEndpointStatsLine(nowS, endpointId, stats) << '\n';
    ++count;
  }

  if (lineCount != nullptr)
  {
    *lineCount = count;
  }
  return oss.str();
}

void
AppendLinkStateHistory(TopologyRuntime &rt,
                       double simTime,
                       double wallTime,
                       const std::string &payload,
                       uint32_t lineCount)
{
  auto &channel = rt.linkState;
  if (channel.historyPath.empty())
  {
    channel.historyPath = LinkStateHistoryPath(rt.config);
  }

  std::ofstream out(channel.historyPath,
                    channel.historyStarted ? std::ios::app : std::ios::trunc);
  if (!out)
  {
    return;
  }

  out << std::fixed << std::setprecision(6)
      << "# wall_unix=" << wallTime
      << " sim_time=" << simTime
      << " line_count=" << lineCount << '\n'
      << payload;
  if (payload.empty() || payload.back() != '\n')
  {
    out << '\n';
  }

  channel.historyStarted = true;
  channel.lastHistoryWallTimeS = wallTime;
}

void
WriteLinkStateSharedSnapshot(TopologyRuntime &rt, double t)
{
  if (!EnsureLinkStateChannelOpen(rt))
  {
    return;
  }

  uint32_t lineCount = 0;
  std::string payload = BuildLinkStateSnapshot(t, rt, &lineCount);
  if (payload.size() > kLinkStatePayloadBytes)
  {
    payload.resize(kLinkStatePayloadBytes);
  }

  auto &channel = rt.linkState;
  const double wallTime = WallUnixSeconds();
  const uint64_t oddSeq = channel.seq + 1;
  const uint64_t evenSeq = channel.seq + 2;

  LinkStateHeader header{};
  std::memcpy(header.magic, kLinkStateMagic, sizeof(header.magic));
  header.version = kLinkStateVersion;
  header.payloadBytes = kLinkStatePayloadBytes;
  header.seq = oddSeq;
  header.simTime = t;
  header.wallTime = wallTime;
  header.usedBytes = static_cast<uint32_t>(payload.size());
  header.lineCount = lineCount;

  std::memcpy(channel.data, &header, sizeof(header));
  if (!payload.empty())
  {
    std::memcpy(channel.data + sizeof(header), payload.data(), payload.size());
  }
  if (payload.size() < kLinkStatePayloadBytes)
  {
    channel.data[sizeof(header) + payload.size()] = '\0';
  }

  header.seq = evenSeq;
  std::memcpy(channel.data, &header, sizeof(header));
  channel.seq = evenSeq;

  if (channel.lastHistoryWallTimeS < 0.0 ||
      wallTime - channel.lastHistoryWallTimeS >= 1.0)
  {
    AppendLinkStateHistory(rt, t, wallTime, payload, lineCount);
  }
}

std::optional<LinkMetricsSample>
ReadLinkMetrics(TopologyRuntime &rt, const LinkSpec &spec)
{
  if (rt.sharedMetrics.snapshotValid)
  {
    const auto it = rt.sharedMetrics.samples.find(spec.id);
    if (it != rt.sharedMetrics.samples.end())
    {
      return it->second;
    }
  }

  return ReadLinkMetrics(spec.metricsFile);
}

std::string
AddressKey(const Address &address)
{
  std::ostringstream oss;
  if (Mac48Address::IsMatchingType(address))
  {
    oss << Mac48Address::ConvertFrom(address);
  }
  else
  {
    oss << address;
  }
  return oss.str();
}

std::string
EndpointPairKey(const std::string &a, const std::string &b)
{
  if (a < b)
  {
    return a + "|" + b;
  }
  return b + "|" + a;
}

bool
IsGroupOrBroadcast(const Address &address)
{
  if (!Mac48Address::IsMatchingType(address))
  {
    return false;
  }

  const Mac48Address mac = Mac48Address::ConvertFrom(address);
  return mac.IsBroadcast() || mac.IsGroup();
}

double
ComputeLoss(const LinkSpec &spec, double dist)
{
  if (dist <= spec.distNoLoss)
  {
    return spec.lossMin;
  }
  if (dist >= spec.distMax)
  {
    return spec.lossMax;
  }

  const double ratio = (dist - spec.distNoLoss) / (spec.distMax - spec.distNoLoss);
  const double loss = spec.lossMin + ratio * (spec.lossMax - spec.lossMin);

  if (loss < spec.lossMin)
  {
    return spec.lossMin;
  }

  if (loss > spec.lossMax)
  {
    return spec.lossMax;
  }

  return loss;
}

void
UpdateEndpointPosition(TopologyRuntime &rt, const std::string &endpointId, const Vector &position)
{
  auto mobilityIt = rt.endpointMobility.find(endpointId);
  if (mobilityIt == rt.endpointMobility.end())
  {
    Fatal("missing endpoint mobility: " + endpointId);
  }

  mobilityIt->second->SetPosition(position);
  auto buildingInfoIt = rt.endpointBuildingInfo.find(endpointId);
  if (buildingInfoIt != rt.endpointBuildingInfo.end())
  {
    buildingInfoIt->second->MakeConsistent(mobilityIt->second);
  }
}

double
ClampPacketErrorProbability(double value, double floor, double cap)
{
  const double safeFloor = std::clamp(floor, 0.0, 1.0);
  const double safeCap = std::clamp(cap, 0.0, 1.0);
  const double upper = std::max(safeFloor, safeCap);
  if (!std::isfinite(value))
  {
    return upper;
  }
  return std::clamp(value, safeFloor, upper);
}

double
ComputePacketErrorRateFromRxPower(const LinkSimulationConfig &sim,
                                  const LinkSpec &spec,
                                  double rxPowerDbm,
                                  double &rawPacketErrorRate)
{
  rawPacketErrorRate = spec.lossMin;

  if (sim.linkErrorModel == "linear_rx_threshold_v1")
  {
    if (rxPowerDbm >= sim.rxSensitivityDbm)
    {
      rawPacketErrorRate = spec.lossMin;
      return ClampPacketErrorProbability(rawPacketErrorRate,
                                         spec.lossMin,
                                         sim.packetErrorRateCap);
    }
    if (rxPowerDbm <= sim.rxLossFullDbm)
    {
      rawPacketErrorRate = 1.0;
      return ClampPacketErrorProbability(rawPacketErrorRate,
                                         spec.lossMin,
                                         sim.packetErrorRateCap);
    }

    const double ratio =
        (sim.rxSensitivityDbm - rxPowerDbm) / (sim.rxSensitivityDbm - sim.rxLossFullDbm);
    rawPacketErrorRate = spec.lossMin + ratio * (1.0 - spec.lossMin);
    return ClampPacketErrorProbability(rawPacketErrorRate,
                                       spec.lossMin,
                                       sim.packetErrorRateCap);
  }

  if (sim.ReceiverSensitivityBler())
  {
    const McsProfile mcsProfile = ResolveMcsProfile(sim);
    const double packetSizeRatio =
        std::max(0.25, std::min(4.0, sim.packetErrorBytes / 1000.0));
    const double packetSizePenaltyDb = 10.0 * std::log10(packetSizeRatio);
    const double sensitivity10PerDbm =
        mcsProfile.sensitivity10PerDbm + packetSizePenaltyDb;
    const double rxPower50PerDbm =
        sensitivity10PerDbm - mcsProfile.transitionDb * std::log(9.0);
    const double effectiveRxPowerDbm = rxPowerDbm - sim.implementationMarginDb;
    const double x = (effectiveRxPowerDbm - rxPower50PerDbm) / mcsProfile.transitionDb;

    double blockErrorRate = 0.0;
    if (x <= -40.0)
    {
      blockErrorRate = 1.0;
    }
    else if (x >= 40.0)
    {
      blockErrorRate = 0.0;
    }
    else
    {
      blockErrorRate = 1.0 / (1.0 + std::exp(x));
    }

    rawPacketErrorRate = blockErrorRate;
    return ClampPacketErrorProbability(blockErrorRate,
                                       spec.lossMin,
                                       sim.packetErrorRateCap);
  }

  const double snrDb = rxPowerDbm - sim.noiseFloorDbm + sim.codingGainDb;
  const double snrLinear = std::pow(10.0, snrDb / 10.0);
  if (!std::isfinite(snrLinear) || snrLinear <= 0.0)
  {
    rawPacketErrorRate = 1.0;
    return ClampPacketErrorProbability(rawPacketErrorRate,
                                       spec.lossMin,
                                       sim.packetErrorRateCap);
  }

  // Coherent BPSK/QPSK AWGN BER approximation. The ns-3 fabric is still an
  // L2 impairment datapath, so this gives RateErrorModel a packet-level error
  // probability derived from SNR and packet length instead of a hand-made
  // rx-power threshold ramp.
  const double bitErrorRate = 0.5 * std::erfc(std::sqrt(snrLinear));
  if (bitErrorRate <= 0.0)
  {
    rawPacketErrorRate = spec.lossMin;
    return ClampPacketErrorProbability(rawPacketErrorRate,
                                       spec.lossMin,
                                       sim.packetErrorRateCap);
  }
  if (bitErrorRate >= 1.0)
  {
    rawPacketErrorRate = 1.0;
    return ClampPacketErrorProbability(rawPacketErrorRate,
                                       spec.lossMin,
                                       sim.packetErrorRateCap);
  }

  const double packetBits = std::max(1.0, sim.packetErrorBytes * 8.0);
  const double packetSuccess = std::exp(packetBits * std::log1p(-bitErrorRate));
  const double packetErrorRate = 1.0 - packetSuccess;
  rawPacketErrorRate = packetErrorRate;
  return ClampPacketErrorProbability(packetErrorRate,
                                     spec.lossMin,
                                     sim.packetErrorRateCap);
}

double
UpdatePacketErrorRateSmoothing(const LinkSimulationConfig &sim,
                               FadingRuntimeState &state,
                               double packetErrorRate)
{
  const double target =
      ClampPacketErrorProbability(packetErrorRate, 0.0, sim.packetErrorRateCap);
  const double nowS = Simulator::Now().GetSeconds();

  if (sim.packetErrorSmoothingTauS <= 0.0 || !state.packetErrorRateInitialized)
  {
    state.packetErrorRateInitialized = true;
    state.packetErrorRate = target;
    state.packetErrorRateLastUpdateS = nowS;
    return state.packetErrorRate;
  }

  const double elapsedS = std::max(0.0, nowS - state.packetErrorRateLastUpdateS);
  const double alpha =
      1.0 - std::exp(-elapsedS / std::max(1.0e-6, sim.packetErrorSmoothingTauS));
  state.packetErrorRate += alpha * (target - state.packetErrorRate);
  state.packetErrorRate =
      ClampPacketErrorProbability(state.packetErrorRate, 0.0, sim.packetErrorRateCap);
  state.packetErrorRateLastUpdateS = nowS;
  return state.packetErrorRate;
}

double
ComputePostMacDropProbability(const LinkSimulationConfig &sim,
                              double phyPacketErrorRate,
                              bool groupOrBroadcast)
{
  // Legacy ns3_pairwise_links approximation. Native Wi-Fi mode delegates this
  // decision to YansWifiPhy/AdhocWifiMac traces and counters.
  const double p = ClampPacketErrorProbability(phyPacketErrorRate, 0.0, 1.0);
  if (!sim.macRetryEnabled || sim.macRetryMaxRetries == 0 ||
      (groupOrBroadcast && !sim.macRetryBroadcast))
  {
    return p;
  }

  const double attempts = static_cast<double>(sim.macRetryMaxRetries + 1);
  return ClampPacketErrorProbability(std::pow(p, attempts), 0.0, 1.0);
}

Time
ComputeExpectedMacRetryDelay(const LinkSimulationConfig &sim,
                             double phyPacketErrorRate,
                             bool groupOrBroadcast)
{
  if (!sim.macRetryEnabled || sim.macRetryMaxRetries == 0 ||
      (groupOrBroadcast && !sim.macRetryBroadcast))
  {
    return MilliSeconds(0);
  }

  const double p = ClampPacketErrorProbability(phyPacketErrorRate, 0.0, 1.0);
  const double successProbability = 1.0 - std::pow(p, sim.macRetryMaxRetries + 1);
  if (successProbability <= 1.0e-12)
  {
    return MilliSeconds(0);
  }

  double expectedFailedAttemptsOnDeliveredPackets = 0.0;
  for (uint32_t failed = 0; failed <= sim.macRetryMaxRetries; ++failed)
  {
    const double successAtThisAttempt = std::pow(p, failed) * (1.0 - p);
    expectedFailedAttemptsOnDeliveredPackets +=
        static_cast<double>(failed) * successAtThisAttempt;
  }
  expectedFailedAttemptsOnDeliveredPackets /= successProbability;

  const Time slot = ParseTimeOrDefault(sim.macRetrySlotTime, MilliSeconds(1));
  const Time jitterMax = ParseTimeOrDefault(sim.macRetryJitterMax, MilliSeconds(0));
  const double delaySec = expectedFailedAttemptsOnDeliveredPackets *
                          (slot.GetSeconds() + 0.5 * jitterMax.GetSeconds());
  return Seconds(std::max(0.0, delaySec));
}

double
ScalePacketErrorRateForPacketSize(const LinkSimulationConfig &sim,
                                  double referencePacketErrorRate,
                                  uint32_t packetBytes)
{
  const double p = ClampPacketErrorProbability(referencePacketErrorRate, 0.0, 1.0);
  if (!sim.packetSizeScalingEnabled || sim.packetErrorBytes <= 0.0 ||
      packetBytes == 0 || p <= 0.0 || p >= 1.0)
  {
    return p;
  }

  const double ratio =
      std::clamp(static_cast<double>(packetBytes) / sim.packetErrorBytes, 0.05, 8.0);
  const double success = std::exp(ratio * std::log1p(-p));
  return ClampPacketErrorProbability(1.0 - success, 0.0, 1.0);
}

Time
ComputeMacFrameAirtime(const LinkSimulationConfig &sim,
                       const LinkSpec &spec,
                       uint32_t packetBytes)
{
  if (!sim.macAirtimeAccounting)
  {
    return MilliSeconds(0);
  }

  const std::string rate = sim.macDataRate.empty() ? spec.dataRate : sim.macDataRate;
  const DataRate dataRate = ParseDataRateOrDefault(rate, spec.dataRate);
  const uint64_t bitRate = dataRate.GetBitRate();
  if (bitRate == 0 || packetBytes == 0)
  {
    return MilliSeconds(0);
  }

  const double seconds =
      (static_cast<double>(packetBytes) * 8.0) / static_cast<double>(bitRate);
  return Seconds(std::max(0.0, seconds));
}

bool
UseSharedRadioMedium(const LinkSimulationConfig &sim)
{
  return sim.macMediumAccess == "shared_radio_serial_dcf_v1";
}

PhyAttemptResult
ComputePairwisePhyAttempt(TopologyRuntime &rt,
                          PairLinkRuntime &pl,
                          uint32_t packetBytes)
{
  PhyAttemptResult result;
  const auto sampleOpt = ReadLinkMetrics(rt, pl.spec);

  if (sampleOpt.has_value())
  {
    pl.lastSpeed = sampleOpt->speed;
    pl.lastDist = sampleOpt->dist;
  }

  bool fromPathloss = false;
  double rawPacketErrorRate = 0.0;
  double rxPowerDbm = std::numeric_limits<double>::quiet_NaN();
  std::string lossModel = "distance_linear";
  double referencePhyPer =
      sampleOpt.has_value()
          ? ComputeLinkLoss(rt, pl.spec, *sampleOpt, pl.fadingState,
                            rxPowerDbm, fromPathloss, lossModel,
                            rawPacketErrorRate)
          : ComputeLoss(pl.spec, pl.lastDist);

  result.rxPowerDbm = rxPowerDbm;
  result.rawPacketErrorRate = sampleOpt.has_value() ? rawPacketErrorRate : referencePhyPer;
  result.phyPerSingleAttempt =
      ScalePacketErrorRateForPacketSize(rt.config.linkSimulation,
                                        referencePhyPer,
                                        packetBytes);
  result.model = lossModel;
  result.airtime =
      ComputeMacFrameAirtime(rt.config.linkSimulation, pl.spec, packetBytes);

  const double draw = (pl.errorRng != nullptr) ? pl.errorRng->GetValue() : 0.0;
  result.decoded = draw >= result.phyPerSingleAttempt;
  result.failureReason = result.decoded ? "none" : "phy_decode";

  pl.currentRawLoss = result.rawPacketErrorRate;
  pl.currentPhyLoss = result.phyPerSingleAttempt;
  pl.currentRxPowerDbm = rxPowerDbm;
  pl.currentLossFromPathloss = fromPathloss;
  pl.currentLossModel = lossModel + "/phy_single_attempt/" +
                        rt.config.linkSimulation.macModel;

  return result;
}

double
ComputeLinkLoss(TopologyRuntime &rt,
                const LinkSpec &spec,
                const LinkMetricsSample &sample,
                FadingRuntimeState &state,
                double &rxPowerDbm,
                bool &fromPathloss,
                std::string &lossModel,
                double &rawPacketErrorRate)
{
  rxPowerDbm = std::numeric_limits<double>::quiet_NaN();
  fromPathloss = false;
  lossModel = "distance_linear";
  rawPacketErrorRate = spec.lossMin;

  const auto &sim = rt.config.linkSimulation;
  if (sim.LargeSmallFading())
  {
    rxPowerDbm = ComputeLargeSmallFadingRxPower(rt, state, sample);
    if (!std::isfinite(rxPowerDbm))
    {
      rawPacketErrorRate = ComputeLoss(spec, sample.dist);
      return rawPacketErrorRate;
    }

    fromPathloss = true;
    lossModel = sim.model + "/" + sim.linkErrorModel;
    const double packetErrorRate =
        ComputePacketErrorRateFromRxPower(sim, spec, rxPowerDbm, rawPacketErrorRate);
    return UpdatePacketErrorRateSmoothing(sim, state, packetErrorRate);
  }

  if (!sim.Ns3BuildingsPathloss() || !sample.hasPositions ||
      rt.propagationLossModel == nullptr)
  {
    rawPacketErrorRate = ComputeLoss(spec, sample.dist);
    return rawPacketErrorRate;
  }

  UpdateEndpointPosition(rt, spec.src, sample.srcPosition);
  UpdateEndpointPosition(rt, spec.dst, sample.dstPosition);

  auto srcMobilityIt = rt.endpointMobility.find(spec.src);
  auto dstMobilityIt = rt.endpointMobility.find(spec.dst);
  if (srcMobilityIt == rt.endpointMobility.end() ||
      dstMobilityIt == rt.endpointMobility.end())
  {
    rawPacketErrorRate = ComputeLoss(spec, sample.dist);
    return rawPacketErrorRate;
  }

  rxPowerDbm =
      rt.propagationLossModel->CalcRxPower(sim.txPowerDbm, srcMobilityIt->second, dstMobilityIt->second);
  fromPathloss = true;
  lossModel = sim.model + "/" + sim.linkErrorModel;
  const double packetErrorRate =
      ComputePacketErrorRateFromRxPower(sim, spec, rxPowerDbm, rawPacketErrorRate);
  return UpdatePacketErrorRateSmoothing(sim, state, packetErrorRate);
}

Time
ComputeJitterAmplitude(const LinkSpec &spec, double speed)
{
  const Time perMps = ParseTimeOrDefault(spec.jitterPerMps, MilliSeconds(0));
  const Time maxJitter = ParseTimeOrDefault(spec.jitterMax, MilliSeconds(10));

  const double absSpeed = (speed < 0.0) ? -speed : speed;

  // 关键修复：
  // 不再用 MilliSeconds(小数毫秒) 构造 Time，避免亚毫秒值再次被量化成 0。
  // 统一在纳秒精度下构造。
  const double jitterNsDouble = perMps.GetSeconds() * absSpeed * 1e9;
  const int64_t jitterNs = static_cast<int64_t>(std::llround(jitterNsDouble));
  const Time jitter = NanoSeconds(jitterNs);

  if (jitter > maxJitter)
  {
    return maxJitter;
  }

  return jitter;
}

Time
ComputeDelay(const LinkSpec &spec, const Time &jitterAmplitude,
             const Ptr<UniformRandomVariable> &rng, Time &appliedJitter)
{
  const Time baseDelay = ParseTimeOrDefault(spec.baseDelay, MilliSeconds(2));

  const double amplitudeSec = jitterAmplitude.GetSeconds();
  const double r = (rng != nullptr) ? rng->GetValue() : 0.0; // [-1, +1]
  const double deltaSec = r * amplitudeSec;

  double delaySec = baseDelay.GetSeconds() + deltaSec;
  if (delaySec < 0.0)
  {
    delaySec = 0.0;
  }

  appliedJitter = Seconds(deltaSec);
  return Seconds(delaySec);
}

void
ApplyLinkState(LinkRuntime &rt, double loss, const Time &appliedJitter, const Time &delay)
{
  rt.currentLoss = loss;
  rt.currentJitter = appliedJitter;
  rt.currentBaseDelay = delay;
  rt.currentRetryDelay = MilliSeconds(0);
  rt.currentDelay = delay;

  if (rt.edgeRxErrorModel != nullptr)
  {
    rt.edgeRxErrorModel->SetRate(loss);
  }

  if (rt.coreRxErrorModel != nullptr)
  {
    rt.coreRxErrorModel->SetRate(loss);
  }

  if (rt.channel != nullptr)
  {
    rt.channel->SetAttribute("Delay", TimeValue(delay));
  }
}

void
UpdatePairwiseLinks(TopologyRuntime &rt)
{
  for (auto &pl : rt.pairLinks)
  {
    const auto sampleOpt = ReadLinkMetrics(rt, pl.spec);

    if (sampleOpt.has_value())
    {
      pl.lastSpeed = sampleOpt->speed;
      pl.lastDist = sampleOpt->dist;
    }

    double rxPowerDbm = std::numeric_limits<double>::quiet_NaN();
    bool fromPathloss = false;
    std::string lossModel = "distance_linear";
    double rawPacketErrorRate = 0.0;
    const double phyPacketErrorRate =
        sampleOpt.has_value()
            ? ComputeLinkLoss(rt, pl.spec, *sampleOpt, pl.fadingState,
                              rxPowerDbm, fromPathloss, lossModel,
                              rawPacketErrorRate)
            : ComputeLoss(pl.spec, pl.lastDist);
    const double postMacUnicastDrop =
        ComputePostMacDropProbability(rt.config.linkSimulation,
                                      phyPacketErrorRate,
                                      false);
    const Time jitterAmplitude = ComputeJitterAmplitude(pl.spec, pl.lastSpeed);
    Time appliedJitter = MilliSeconds(0);
    const Time delay = ComputeDelay(pl.spec, jitterAmplitude, pl.jitterRng, appliedJitter);

    pl.currentJitter = appliedJitter;
    pl.currentBaseDelay = delay;
    pl.currentMacExpectedDrop = postMacUnicastDrop;
    pl.currentDelay = delay + pl.currentQueueDelay + pl.currentBusyDelay +
                      pl.currentRetryDelay + pl.currentAirtime;
    if (pl.packetErrorModel != nullptr)
    {
      pl.packetErrorModel->SetRate(postMacUnicastDrop);
    }
    pl.currentRawLoss = sampleOpt.has_value() ? rawPacketErrorRate : phyPacketErrorRate;
    pl.currentPhyLoss = phyPacketErrorRate;
    pl.currentRxPowerDbm = rxPowerDbm;
    pl.currentLossFromPathloss = fromPathloss;
    pl.currentLoss = postMacUnicastDrop;
    pl.currentLossModel = lossModel + "/phy_single_attempt/" +
                          rt.config.linkSimulation.macModel;
  }
}

void
UpdateWifiAdhocLinks(TopologyRuntime &rt)
{
  if (rt.wifiLossModel == nullptr)
  {
    Fatal("missing Wi-Fi matrix propagation loss model");
  }

  constexpr double kWifiDefaultLossDb = 300.0;
  const double nan = std::numeric_limits<double>::quiet_NaN();

  struct EndpointPositionUpdate
  {
    Vector position;
    bool fromMetrics{false};
  };

  auto recordEndpointPosition =
      [](std::map<std::string, EndpointPositionUpdate> &positions,
         const std::string &endpointId,
         const Vector &position,
         bool fromMetrics) {
        auto it = positions.find(endpointId);
        if (it == positions.end() || fromMetrics || !it->second.fromMetrics)
        {
          positions[endpointId] = EndpointPositionUpdate{position, fromMetrics};
        }
      };

  std::map<std::string, EndpointPositionUpdate> endpointPositions;
  std::vector<LinkMetricsSample> samples;
  samples.reserve(rt.pairLinks.size());

  for (const auto &pl : rt.pairLinks)
  {
    const auto sampleOpt = ReadLinkMetrics(rt, pl.spec);
    LinkMetricsSample sample;

    if (sampleOpt.has_value())
    {
      sample = *sampleOpt;
    }
    else
    {
      const Vector srcFallback = EndpointFallbackPosition(rt.config, pl.spec.src);
      const Vector dstFallback = EndpointFallbackPosition(rt.config, pl.spec.dst);
      sample.speed = 0.0;
      sample.dist = Distance3d(srcFallback, dstFallback);
      sample.srcPosition = srcFallback;
      sample.dstPosition = dstFallback;
      sample.valid = true;
      sample.modelSeen = false;
      sample.hasPositions = false;
    }

    const Vector srcPosition =
        sample.hasPositions ? sample.srcPosition
                            : EndpointFallbackPosition(rt.config, pl.spec.src);
    const Vector dstPosition =
        sample.hasPositions ? sample.dstPosition
                            : EndpointFallbackPosition(rt.config, pl.spec.dst);
    if (sample.dist <= 0.0 || !std::isfinite(sample.dist))
    {
      sample.dist = Distance3d(srcPosition, dstPosition);
    }

    recordEndpointPosition(endpointPositions,
                           pl.spec.src,
                           srcPosition,
                           sample.hasPositions);
    recordEndpointPosition(endpointPositions,
                           pl.spec.dst,
                           dstPosition,
                           sample.hasPositions);
    samples.push_back(sample);
  }

  for (const auto &[endpointId, update] : endpointPositions)
  {
    UpdateEndpointPosition(rt, endpointId, update.position);
  }

  for (std::size_t i = 0; i < rt.pairLinks.size(); ++i)
  {
    auto &pl = rt.pairLinks.at(i);
    const LinkMetricsSample &sample = samples.at(i);

    auto srcMobilityIt = rt.endpointMobility.find(pl.spec.src);
    auto dstMobilityIt = rt.endpointMobility.find(pl.spec.dst);
    if (srcMobilityIt == rt.endpointMobility.end() ||
        dstMobilityIt == rt.endpointMobility.end())
    {
      Fatal("missing endpoint mobility while updating Wi-Fi matrix link: " +
            pl.spec.id);
    }

    const double rxPowerDbm =
        ComputeWifiMatrixRxPower(rt, pl.fadingState, pl.spec, sample);
    double totalLossDb = kWifiDefaultLossDb;
    if (std::isfinite(rxPowerDbm))
    {
      totalLossDb =
          std::clamp(rt.config.linkSimulation.txPowerDbm - rxPowerDbm,
                     0.0,
                     kWifiDefaultLossDb);
    }
    rt.wifiLossModel->SetLoss(srcMobilityIt->second,
                              dstMobilityIt->second,
                              totalLossDb,
                              true);

    pl.lastSpeed = sample.speed;
    pl.lastDist = sample.dist;
    pl.currentRawLoss = nan;
    pl.currentPhyLoss = nan;
    pl.currentLoss = nan;
    pl.currentMacExpectedDrop = nan;
    pl.currentMacDeliveryLoss = nan;
    pl.currentMacRetryAvg = nan;
    pl.currentRxPowerDbm = rxPowerDbm;
    pl.currentLossFromPathloss = true;
    pl.currentJitter = MilliSeconds(0);
    pl.currentBaseDelay = MilliSeconds(0);
    pl.currentRetryDelay = MilliSeconds(0);
    pl.currentQueueDelay = MilliSeconds(0);
    pl.currentBusyDelay = MilliSeconds(0);
    pl.currentAirtime = MilliSeconds(0);
    pl.currentDelay = MilliSeconds(0);
    pl.currentMacDropReason = "delegated_to_ns3_wifi";
    pl.currentLossModel =
        "matrix_large_small_fading_v1/ns3_wifi_ad_hoc/native_wifi_phy_mac";
  }
}

bool
CorePromiscReceive(Ptr<NetDevice> device, Ptr<const Packet> packet,
                   uint16_t protocol, const Address &src,
                   const Address &dst, NetDevice::PacketType packetType)
{
  (void)packetType;

  if (g_runtime == nullptr || device == nullptr || packet == nullptr)
  {
    return true;
  }

  for (uint32_t i = 0; i < g_runtime->corePorts.size(); ++i)
  {
    if (g_runtime->corePorts[i].device == device)
    {
      ForwardPairwiseFrame(*g_runtime, i, packet, protocol, src, dst);
      return true;
    }
  }

  return true;
}

void
SendPairwiseFrame(Ptr<NetDevice> outDevice, Ptr<Packet> packet,
                  Address src, Address dst, uint16_t protocol)
{
  if (outDevice != nullptr && packet != nullptr)
  {
    outDevice->SendFrom(packet, src, dst, protocol);
  }
}

void
CompletePairwiseMacDelivery(TopologyRuntime &rt,
                            PairLinkRuntime &pl,
                            const MacDeliveryResult &result)
{
  (void)rt;
  if (result.consumesPendingFrame && pl.pendingMacFrames > 0)
  {
    --pl.pendingMacFrames;
  }
  if (result.consumesPendingFrame && result.packetBytes > 0)
  {
    if (pl.pendingMacBytes >= result.packetBytes)
    {
      pl.pendingMacBytes -= result.packetBytes;
    }
    else
    {
      pl.pendingMacBytes = 0;
    }
  }

  pl.macPhyAttempts += result.attempts;
  pl.macRetryAttempts += result.retryCount;
  pl.currentQueueDelay = result.queueDelay;
  pl.currentBusyDelay = result.busyDelay;
  pl.currentRetryDelay = result.retryDelay;
  pl.currentAirtime = result.airtime;
  pl.currentMacDropReason = result.dropReason;

  if (result.delivered)
  {
    ++pl.forwarded;
    ++pl.macDelivered;
  }
  else
  {
    ++pl.dropped;
    ++pl.macDropped;
    if (result.dropReason == "retry_limit")
    {
      ++pl.macDroppedRetryLimit;
    }
    else if (result.dropReason == "broadcast_no_retry")
    {
      ++pl.macDroppedBroadcastNoRetry;
    }
  }

  const uint64_t macTotal = pl.macDelivered + pl.macDropped;
  pl.currentMacDeliveryLoss =
      (macTotal > 0) ? static_cast<double>(pl.macDropped) / static_cast<double>(macTotal) : 0.0;
  pl.currentMacRetryAvg =
      (macTotal > 0) ? static_cast<double>(pl.macRetryAttempts) / static_cast<double>(macTotal) : 0.0;
  pl.currentDelay = pl.currentBaseDelay + result.queueDelay + result.busyDelay +
                    result.retryDelay + result.airtime;
}

void
EnqueuePairwiseMacFrame(TopologyRuntime &rt, std::size_t pairIndex,
                        uint32_t egressPort, Ptr<Packet> packet,
                        uint16_t protocol, Address src, Address dst,
                        bool groupOrBroadcast)
{
  // Legacy ns3_pairwise_links MAC state machine. ns3_wifi_ad_hoc traffic never
  // enters this queue; native Wi-Fi owns contention, retry, and final drop.
  if (pairIndex >= rt.pairLinks.size() || packet == nullptr)
  {
    return;
  }

  PairLinkRuntime &pl = rt.pairLinks[pairIndex];
  const uint32_t packetBytes = packet->GetSize();
  if (pl.pendingMacFrames >= rt.config.linkSimulation.macQueueLimitPackets)
  {
    MacDeliveryResult result;
    result.delivered = false;
    result.dropReason = "queue_overflow";
    result.packetBytes = packetBytes;
    result.consumesPendingFrame = false;
    ++pl.macDroppedQueue;
    CompletePairwiseMacDelivery(rt, pl, result);
    return;
  }

  ++pl.pendingMacFrames;
  pl.pendingMacBytes += packetBytes;
  Simulator::ScheduleNow(&ProcessPairwiseMacAttempt,
                         &rt,
                         pairIndex,
                         egressPort,
                         packet,
                         protocol,
                         src,
                         dst,
                         groupOrBroadcast,
                         0,
                         Simulator::Now(),
                         false,
                         MilliSeconds(0),
                         MilliSeconds(0),
                         MilliSeconds(0),
                         MilliSeconds(0),
                         0.0);
}

void
ProcessPairwiseMacAttempt(TopologyRuntime *rt,
                          std::size_t pairIndex,
                          uint32_t egressPort,
                          Ptr<Packet> packet,
                          uint16_t protocol,
                          Address src,
                          Address dst,
                          bool groupOrBroadcast,
                          uint32_t attempt,
                          Time enqueueTime,
                          bool firstAttemptStarted,
                          Time queueDelay,
                          Time busyDelay,
                          Time retryDelay,
                          Time airtime,
                          double firstAttemptPer)
{
  // Legacy-only retry loop for the synthetic pairwise MAC path.
  if (rt == nullptr || pairIndex >= rt->pairLinks.size() ||
      egressPort >= rt->corePorts.size() || packet == nullptr)
  {
    return;
  }

  PairLinkRuntime &pl = rt->pairLinks[pairIndex];
  const auto &sim = rt->config.linkSimulation;
  const Time now = Simulator::Now();
  const Time mediumReady = UseSharedRadioMedium(sim) ? rt->radioBusyUntil : pl.macBusyUntil;
  if (now < mediumReady)
  {
    const Time wait = mediumReady - now;
    const Time slot = ParseTimeOrDefault(sim.macRetrySlotTime, MilliSeconds(1));
    const Time jitterMax = ParseTimeOrDefault(sim.macRetryJitterMax, MilliSeconds(0));
    const double jitter = (pl.backoffRng != nullptr) ? pl.backoffRng->GetValue() : 0.0;
    const Time backoff =
        Seconds(std::max(0.0, slot.GetSeconds() + jitter * jitterMax.GetSeconds()));
    Simulator::Schedule(wait + backoff,
                         &ProcessPairwiseMacAttempt,
                         rt,
                         pairIndex,
                         egressPort,
                         packet,
                         protocol,
                         src,
                         dst,
                         groupOrBroadcast,
                         attempt,
                         enqueueTime,
                         firstAttemptStarted,
                         queueDelay,
                         busyDelay + (firstAttemptStarted ? wait + backoff : MilliSeconds(0)),
                         retryDelay,
                         airtime,
                         firstAttemptPer);
    return;
  }

  if (!firstAttemptStarted)
  {
    queueDelay = now - enqueueTime;
    firstAttemptStarted = true;
  }

  PhyAttemptResult phy = ComputePairwisePhyAttempt(*rt, pl, packet->GetSize());
  if (attempt == 0)
  {
    firstAttemptPer = phy.phyPerSingleAttempt;
  }

  const bool retryAllowed =
      sim.macRetryEnabled && sim.macRetryMaxRetries > 0 &&
      (!groupOrBroadcast || sim.macRetryBroadcast);
  const uint32_t maxRetries = retryAllowed ? sim.macRetryMaxRetries : 0;
  const Time ackAirtime =
      (!groupOrBroadcast && phy.decoded) ? ComputeMacFrameAirtime(sim, pl.spec, 14) : MilliSeconds(0);
  const Time channelOccupancy = phy.airtime + ackAirtime;
  const Time jitterAmplitude = ComputeJitterAmplitude(pl.spec, pl.lastSpeed);
  Time appliedJitter = MilliSeconds(0);
  const Time propagationDelay =
      ComputeDelay(pl.spec, jitterAmplitude, pl.jitterRng, appliedJitter);

  pl.currentJitter = appliedJitter;
  pl.currentBaseDelay = propagationDelay;
  if (UseSharedRadioMedium(sim))
  {
    rt->radioBusyUntil = now + channelOccupancy;
    ++rt->radioTxAttempts;
    rt->radioAirtimeSeconds += channelOccupancy.GetSeconds();
  }
  else
  {
    pl.macBusyUntil = now + channelOccupancy;
  }

  MacDeliveryResult result;
  result.attempts = attempt + 1;
  result.retryCount = attempt;
  result.queueDelay = queueDelay;
  result.busyDelay = busyDelay;
  result.retryDelay = retryDelay;
  result.airtime = airtime + channelOccupancy;
  result.firstAttemptPer = firstAttemptPer;
  result.lastAttemptPer = phy.phyPerSingleAttempt;
  result.lastRxPowerDbm = phy.rxPowerDbm;
  result.packetBytes = packet->GetSize();

  if (phy.decoded)
  {
    result.delivered = true;
    result.dropReason = "none";
    CompletePairwiseMacDelivery(*rt, pl, result);
    Simulator::Schedule(phy.airtime + propagationDelay,
                        &SendPairwiseFrame,
                        rt->corePorts[egressPort].device,
                        packet,
                        src,
                        dst,
                        protocol);
    return;
  }

  if (attempt >= maxRetries)
  {
    result.delivered = false;
    result.dropReason = groupOrBroadcast ? "broadcast_no_retry" : "retry_limit";
    CompletePairwiseMacDelivery(*rt, pl, result);
    return;
  }

  const Time slot = ParseTimeOrDefault(sim.macRetrySlotTime, MilliSeconds(1));
  const Time jitterMax = ParseTimeOrDefault(sim.macRetryJitterMax, MilliSeconds(0));
  const double jitter = (pl.retryJitterRng != nullptr) ? pl.retryJitterRng->GetValue() : 0.0;
  const Time retryWait =
      Seconds(std::max(0.0, slot.GetSeconds() + jitter * jitterMax.GetSeconds()));

  Simulator::Schedule(phy.airtime + retryWait,
                       &ProcessPairwiseMacAttempt,
                       rt,
                       pairIndex,
                       egressPort,
                       packet,
                       protocol,
                       src,
                       dst,
                       groupOrBroadcast,
                       attempt + 1,
                       enqueueTime,
                       firstAttemptStarted,
                       queueDelay,
                       busyDelay,
                       retryDelay + retryWait,
                       airtime + channelOccupancy,
                       firstAttemptPer);
}

void
ForwardPairwiseFrame(TopologyRuntime &rt, uint32_t ingressPort,
                     Ptr<const Packet> packet, uint16_t protocol,
                     const Address &src, const Address &dst)
{
  if (ingressPort >= rt.corePorts.size())
  {
    return;
  }

  const std::string srcKey = AddressKey(src);
  const std::string dstKey = AddressKey(dst);
  if (!srcKey.empty())
  {
    rt.learnedMacToPort[srcKey] = ingressPort;
  }

  const bool groupOrBroadcast = IsGroupOrBroadcast(dst);

  std::vector<uint32_t> egressPorts;
  if (!groupOrBroadcast)
  {
    auto learnedIt = rt.learnedMacToPort.find(dstKey);
    if (learnedIt != rt.learnedMacToPort.end())
    {
      if (learnedIt->second != ingressPort)
      {
        egressPorts.push_back(learnedIt->second);
      }
    }
    else
    {
      for (uint32_t i = 0; i < rt.corePorts.size(); ++i)
      {
        if (i != ingressPort)
        {
          egressPorts.push_back(i);
        }
      }
    }
  }
  else
  {
    for (uint32_t i = 0; i < rt.corePorts.size(); ++i)
    {
      if (i != ingressPort)
      {
        egressPorts.push_back(i);
      }
    }
  }

  const std::string &srcEndpoint = rt.corePorts[ingressPort].endpointId;
  for (const uint32_t egressPort : egressPorts)
  {
    if (egressPort >= rt.corePorts.size())
    {
      continue;
    }

    const std::string &dstEndpoint = rt.corePorts[egressPort].endpointId;
    const std::string pairKey = EndpointPairKey(srcEndpoint, dstEndpoint);
    auto pairIt = rt.pairLinkIndexByEndpointKey.find(pairKey);
    if (pairIt == rt.pairLinkIndexByEndpointKey.end())
    {
      Fatal("missing pairwise impairment runtime link: " + srcEndpoint + " <-> " +
            dstEndpoint);
    }

    EnqueuePairwiseMacFrame(rt,
                            pairIt->second,
                            egressPort,
                            packet->Copy(),
                            protocol,
                            src,
                            dst,
                            groupOrBroadcast);
  }
}

void
LogTopologySummary(const TopologyRuntime &rt)
{
  const auto &cfg = rt.config;
  const auto uavs = GetUavInstances(cfg);
  const auto enabledLinks = GetEnabledGsUavLinks(cfg);

  std::ostringstream oss1;
  oss1 << "[topo] scenario=" << cfg.globals.scenarioId
       << " fabric=" << cfg.globals.fabricMode;
  LogInfo(oss1.str(), rt.verbose);

  std::ostringstream oss2;
  oss2 << "[topo] gs=" << cfg.globals.gsId
       << " tap=" << cfg.globals.tapLeft
       << " uavs=" << uavs.size()
       << " access_links=" << enabledLinks.size()
       << " pairwise_links=" << rt.pairLinks.size();
  LogInfo(oss2.str(), rt.verbose);

  std::ostringstream oss3;
  const std::string linkSimulationModel =
      cfg.linkSimulation.enabled ? cfg.linkSimulation.model : "distance_linear";
  oss3 << "[topo] time_file=" << cfg.globals.timeFile
       << " shared_metrics=" << SharedMetricsPath(cfg)
       << " tick=" << cfg.globals.tick
       << " impairment_policy=" << cfg.globals.impairmentPolicy
       << " link_simulation=" << linkSimulationModel
       << " pcap=" << (cfg.globals.pcap ? 1 : 0)
       << " verbose=" << (cfg.globals.verbose ? 1 : 0)
       << " stop_time=" << cfg.globals.stopTime;
  LogInfo(oss3.str(), rt.verbose);
}

void
LogLinkInit(const LinkRuntime &rt, bool verbose)
{
  std::ostringstream oss;
  oss << "[link-init] id=" << rt.spec.id
      << " src=" << rt.spec.src
      << " dst=" << rt.spec.dst
      << " metrics=" << rt.spec.metricsFile
      << " rate=" << rt.spec.dataRate
      << " delay=" << rt.spec.baseDelay
      << " loss=[" << rt.spec.lossMin << "," << rt.spec.lossMax << "]"
      << " dist=[" << rt.spec.distNoLoss << "," << rt.spec.distMax << "]"
      << " jitter_per_mps=" << rt.spec.jitterPerMps
      << " jitter_max=" << rt.spec.jitterMax;
  LogInfo(oss.str(), verbose);
}

std::string
LinkStateLine(double t, const LinkRuntime &rt)
{
  const double jitterMs = rt.currentJitter.GetSeconds() * 1000.0;
  const double delayMs = rt.currentDelay.GetSeconds() * 1000.0;

  std::ostringstream oss;
  oss << std::fixed << std::setprecision(3)
      << "[link] t=" << t
      << " id=" << rt.spec.id
      << " speed=" << rt.lastSpeed
      << " dist=" << rt.lastDist
      << " loss=" << rt.currentLoss
      << " post_mac_drop=" << rt.currentLoss
      << " phy_per=" << rt.currentPhyLoss
      << " raw_per=" << rt.currentRawLoss
      << " jitter_ms=" << jitterMs
      << " retry_delay_ms=" << rt.currentRetryDelay.GetSeconds() * 1000.0
      << " delay_ms=" << delayMs
      << " loss_model=" << rt.currentLossModel
      << " path_loss_db=" << rt.fadingState.pathLossDb
      << " shadow_db=" << rt.fadingState.shadowDb
      << " obstruction_loss_db=" << rt.fadingState.obstructionLossDb
      << " obstruction_raw_loss_db=" << rt.fadingState.obstructionRawLossDb
      << " channel_state=" << rt.fadingState.channelState
      << " multipath_db=" << rt.fadingState.multipathDeltaDb
      << " multipath_resampled=" << (rt.fadingState.multipathResampled ? 1 : 0);
  if (std::isfinite(rt.currentRxPowerDbm))
  {
    oss << " rx_dbm=" << rt.currentRxPowerDbm;
  }
  return oss.str();
}

void
LogLinkState(double t, const LinkRuntime &rt, bool verbose)
{
  LogInfo(LinkStateLine(t, rt), verbose);
}

void
LogPairLinkInit(const PairLinkRuntime &rt, bool verbose)
{
  std::ostringstream oss;
  oss << "[pair-init] id=" << rt.spec.id
      << " src=" << rt.spec.src
      << " dst=" << rt.spec.dst
      << " metrics=" << rt.spec.metricsFile
      << " rate=" << rt.spec.dataRate
      << " delay=" << rt.spec.baseDelay
      << " loss=[" << rt.spec.lossMin << "," << rt.spec.lossMax << "]"
      << " dist=[" << rt.spec.distNoLoss << "," << rt.spec.distMax << "]"
      << " jitter_per_mps=" << rt.spec.jitterPerMps
      << " jitter_max=" << rt.spec.jitterMax;
  LogInfo(oss.str(), verbose);
}

std::string
PairLinkStateLine(double t, const PairLinkRuntime &rt)
{
  const double jitterMs = rt.currentJitter.GetSeconds() * 1000.0;
  const double delayMs = rt.currentDelay.GetSeconds() * 1000.0;
  const bool delegatedToNativeWifi =
      rt.currentMacDropReason == "delegated_to_ns3_wifi";

  std::ostringstream oss;
  oss << std::fixed << std::setprecision(3)
      << "[pair-link] t=" << t
      << " id=" << rt.spec.id
      << " speed=" << rt.lastSpeed
      << " dist=" << rt.lastDist;
  if (delegatedToNativeWifi)
  {
    oss << " drop_authority=ns3_wifi_phy_mac"
        << " legacy_loss=delegated_to_ns3_wifi";
  }
  else
  {
    oss << " loss=" << rt.currentLoss
        << " post_mac_drop=" << rt.currentLoss
        << " mac_delivery_loss=" << rt.currentMacDeliveryLoss
        << " mac_expected_drop=" << rt.currentMacExpectedDrop
        << " phy_per=" << rt.currentPhyLoss
        << " raw_per=" << rt.currentRawLoss
        << " jitter_ms=" << jitterMs
        << " retry_delay_ms=" << rt.currentRetryDelay.GetSeconds() * 1000.0
        << " queue_delay_ms=" << rt.currentQueueDelay.GetSeconds() * 1000.0
        << " busy_delay_ms=" << rt.currentBusyDelay.GetSeconds() * 1000.0
        << " airtime_ms=" << rt.currentAirtime.GetSeconds() * 1000.0
        << " queue_service_ms=" << rt.currentAirtime.GetSeconds() * 1000.0
        << " queue_busy_ms=" << rt.currentBusyDelay.GetSeconds() * 1000.0
        << " delay_ms=" << delayMs
        << " mac_retry_count_avg=" << rt.currentMacRetryAvg
        << " mac_drop_reason=" << rt.currentMacDropReason
        << " mac_pending=" << rt.pendingMacFrames
        << " mac_delivered=" << rt.macDelivered
        << " mac_dropped=" << rt.macDropped
        << " mac_phy_attempts=" << rt.macPhyAttempts
        << " queue_packets=" << rt.pendingMacFrames
        << " queue_bytes=" << rt.pendingMacBytes
        << " queue_dropped=" << rt.macDroppedQueue;
  }
  oss
      << " loss_model=" << rt.currentLossModel
      << " path_loss_db=" << rt.fadingState.pathLossDb
      << " shadow_db=" << rt.fadingState.shadowDb
      << " obstruction_loss_db=" << rt.fadingState.obstructionLossDb
      << " obstruction_raw_loss_db=" << rt.fadingState.obstructionRawLossDb
      << " channel_state=" << rt.fadingState.channelState
      << " multipath_db=" << rt.fadingState.multipathDeltaDb
      << " multipath_resampled=" << (rt.fadingState.multipathResampled ? 1 : 0);
  if (!delegatedToNativeWifi)
  {
    oss << " forwarded=" << rt.forwarded
        << " dropped=" << rt.dropped;
  }
  if (std::isfinite(rt.currentRxPowerDbm))
  {
    oss << " rx_dbm=" << rt.currentRxPowerDbm;
  }
  return oss.str();
}

void
LogPairLinkState(double t, const PairLinkRuntime &rt, bool verbose)
{
  LogInfo(PairLinkStateLine(t, rt), verbose);
}

std::string
WifiEndpointStatsLine(double t, const std::string &endpointId, const WifiEndpointStats &stats)
{
  std::ostringstream oss;
  oss << std::fixed << std::setprecision(3)
      << "[wifi] t=" << t
      << " endpoint=" << endpointId
      << " mac_tx_packets=" << stats.macTxPackets
      << " mac_tx_bytes=" << stats.macTxBytes
      << " mac_rx_packets=" << stats.macRxPackets
      << " mac_rx_bytes=" << stats.macRxBytes
      << " mac_promisc_rx_packets=" << stats.macPromiscRxPackets
      << " mac_promisc_rx_bytes=" << stats.macPromiscRxBytes
      << " mac_tx_drop_packets=" << stats.macTxDropPackets
      << " mac_rx_drop_packets=" << stats.macRxDropPackets
      << " phy_tx_begin_packets=" << stats.phyTxBeginPackets
      << " phy_tx_begin_bytes=" << stats.phyTxBeginBytes
      << " phy_tx_end_packets=" << stats.phyTxEndPackets
      << " phy_tx_drop_packets=" << stats.phyTxDropPackets
      << " phy_rx_begin_packets=" << stats.phyRxBeginPackets
      << " phy_rx_begin_bytes=" << stats.phyRxBeginBytes
      << " phy_rx_end_packets=" << stats.phyRxEndPackets
      << " phy_rx_end_bytes=" << stats.phyRxEndBytes
      << " phy_rx_drop_packets=" << stats.phyRxDropPackets
      << " acked_mpdu=" << stats.ackedMpdu
      << " nacked_mpdu=" << stats.nackedMpdu
      << " dropped_mpdu=" << stats.droppedMpdu
      << " final_data_failed=" << stats.finalDataFailed
      << " retry_limit_drops=" << stats.retryLimitDrops
      << " retry_count=" << stats.retryCountTotal
      << " mpdu_response_timeout=" << stats.mpduResponseTimeouts
      << " last_mac_drop_reason=" << stats.lastMacDropReason
      << " last_phy_rx_drop_reason=" << stats.lastPhyRxDropReason
      << " last_response_timeout_reason=" << stats.lastResponseTimeoutReason;
  return oss.str();
}

void
LogWifiEndpointStats(TopologyRuntime &rt, double t)
{
  if (rt.wifiEndpointStats.empty())
  {
    return;
  }

  const double nowS = std::max(t, Simulator::Now().GetSeconds());
  if (rt.lastWifiStatsLogTimeS >= 0.0 &&
      nowS - rt.lastWifiStatsLogTimeS < 1.0)
  {
    return;
  }
  rt.lastWifiStatsLogTimeS = nowS;

  for (const auto &[endpointId, stats] : rt.wifiEndpointStats)
  {
    LogInfo(WifiEndpointStatsLine(nowS, endpointId, stats), rt.verbose);
  }
}

void
RenderStatusPanel(TopologyRuntime &rt, double t)
{
  if (!rt.ttyUi)
  {
    return;
  }

  const bool nativeWifi = rt.config.globals.Ns3WifiAdhoc();
  const uint32_t desiredRows =
      nativeWifi
          ? 3 + static_cast<uint32_t>(rt.pairLinks.size() +
                                      rt.wifiEndpointStats.size())
          : 2 + static_cast<uint32_t>(
                    rt.config.globals.EndpointPairLinkImpairment()
                        ? rt.pairLinks.size()
                        : rt.dynamicLinks.size());

  if (!rt.uiInitialized || rt.uiRows != desiredRows)
  {
    if (rt.uiInitialized)
    {
      std::cout << '\n';
    }
    rt.uiRows = desiredRows;
    for (uint32_t i = 0; i < rt.uiRows; ++i)
    {
      std::cout << '\n';
    }
    rt.uiInitialized = true;
  }

  std::cout << "\033[" << rt.uiRows << "A";

  auto writeLine = [](const std::string &s) {
    std::cout << "\r\033[2K" << s << '\n';
  };
  auto fmt = [](double value, int precision = 3) {
    if (!std::isfinite(value))
    {
      return std::string("--");
    }
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(precision) << value;
    return oss.str();
  };

  {
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(3)
        << "[status] scenario=" << rt.config.globals.scenarioId
        << " t=" << t
        << " tick=" << rt.config.globals.tick
        << " mode="
        << (nativeWifi ? "native_wifi_ad_hoc" : "legacy_pairwise")
        << " links="
        << (nativeWifi || rt.config.globals.EndpointPairLinkImpairment()
                ? rt.pairLinks.size()
                : rt.dynamicLinks.size())
        << " endpoints=" << rt.wifiEndpointStats.size();
    writeLine(oss.str());
  }

  if (nativeWifi)
  {
    writeLine("metric-pair  speed(m/s)   dist(m)    rx_dbm matrix_loss channel_state");

    for (const auto &pl : rt.pairLinks)
    {
      const double matrixLossDb =
          std::isfinite(pl.currentRxPowerDbm)
              ? rt.config.linkSimulation.txPowerDbm - pl.currentRxPowerDbm
              : std::numeric_limits<double>::quiet_NaN();

      std::ostringstream oss;
      oss << std::left << std::setw(12) << pl.spec.id
          << std::right
          << std::setw(11) << fmt(pl.lastSpeed)
          << std::setw(11) << fmt(pl.lastDist)
          << std::setw(10) << fmt(pl.currentRxPowerDbm, 1)
          << std::setw(12) << fmt(matrixLossDb, 1)
          << " " << pl.fadingState.channelState;
      writeLine(oss.str());
    }

    writeLine("endpoint      mac_tx/rx   phy_tx/rx phy_rx_drop retry final_fail timeout");
    for (const auto &[endpointId, stats] : rt.wifiEndpointStats)
    {
      std::ostringstream macTxRx;
      macTxRx << stats.macTxPackets << "/" << stats.macRxPackets;
      std::ostringstream phyTxRx;
      phyTxRx << stats.phyTxBeginPackets << "/" << stats.phyRxEndPackets;

      std::ostringstream oss;
      oss << std::left << std::setw(12) << endpointId
          << std::right << std::setw(11) << macTxRx.str()
          << std::setw(12) << phyTxRx.str()
          << std::setw(12) << stats.phyRxDropPackets
          << std::setw(6) << stats.retryCountTotal
          << std::setw(11) << stats.finalDataFailed
          << std::setw(8) << stats.mpduResponseTimeouts;
      writeLine(oss.str());
    }

    std::cout.flush();
    return;
  }

  writeLine("link         speed(m/s)   dist(m) drop(post)  phy_per jitter_delta(ms) delay(ms)");

  if (rt.config.globals.EndpointPairLinkImpairment())
  {
    for (const auto &pl : rt.pairLinks)
    {
      const double jitterMs = pl.currentJitter.GetSeconds() * 1000.0;
      const double delayMs = pl.currentDelay.GetSeconds() * 1000.0;

      std::ostringstream oss;
      oss << std::left << std::setw(12) << pl.spec.id
          << std::right << std::fixed << std::setprecision(3)
          << std::setw(11) << pl.lastSpeed
          << std::setw(11) << pl.lastDist
          << std::setw(11) << pl.currentLoss
          << std::setw(9) << pl.currentPhyLoss
          << std::setw(12) << jitterMs
          << std::setw(11) << delayMs;
      writeLine(oss.str());
    }
  }
  else
  {
    for (const auto &lr : rt.dynamicLinks)
    {
      const double jitterMs = lr.currentJitter.GetSeconds() * 1000.0;
      const double delayMs = lr.currentDelay.GetSeconds() * 1000.0;

      std::ostringstream oss;
      oss << std::left << std::setw(12) << lr.spec.id
          << std::right << std::fixed << std::setprecision(3)
          << std::setw(11) << lr.lastSpeed
          << std::setw(11) << lr.lastDist
          << std::setw(11) << lr.currentLoss
          << std::setw(9) << lr.currentPhyLoss
          << std::setw(12) << jitterMs
          << std::setw(11) << delayMs;
      writeLine(oss.str());
    }
  }

  std::cout.flush();
}

void
CleanupUi(TopologyRuntime &rt)
{
  if (!rt.ttyUi || !rt.uiInitialized)
  {
    return;
  }

  std::cout << '\n' << std::flush;
}

void
OnPeriodicUpdate(TopologyRuntime *rt)
{
  if (rt == nullptr)
  {
    return;
  }

  const bool sharedMetricsReady = RefreshSharedMetricsSnapshot(*rt);
  const auto tOpt = sharedMetricsReady
                        ? std::optional<double>(rt->sharedMetrics.simTime)
                        : ReadSharedTime(rt->config.globals.timeFile);
  const double t = tOpt.value_or(0.0);

  for (auto &lr : rt->dynamicLinks)
  {
    if (rt->config.globals.DynamicAccessImpairment())
    {
      const auto sampleOpt = ReadLinkMetrics(*rt, lr.spec);

      if (sampleOpt.has_value())
      {
        lr.lastSpeed = sampleOpt->speed;
        lr.lastDist = sampleOpt->dist;
      }

      double rxPowerDbm = std::numeric_limits<double>::quiet_NaN();
      bool fromPathloss = false;
      std::string lossModel = "distance_linear";
      double rawPacketErrorRate = 0.0;
      const double phyPacketErrorRate =
          sampleOpt.has_value()
              ? ComputeLinkLoss(*rt, lr.spec, *sampleOpt, lr.fadingState,
                                rxPowerDbm, fromPathloss, lossModel,
                                rawPacketErrorRate)
              : ComputeLoss(lr.spec, lr.lastDist);
      const double postMacDrop =
          ComputePostMacDropProbability(rt->config.linkSimulation,
                                        phyPacketErrorRate,
                                        false);
      const Time jitterAmplitude = ComputeJitterAmplitude(lr.spec, lr.lastSpeed);
      Time appliedJitter = MilliSeconds(0);
      const Time delay = ComputeDelay(lr.spec, jitterAmplitude, lr.jitterRng, appliedJitter) +
                         ComputeExpectedMacRetryDelay(rt->config.linkSimulation,
                                                      phyPacketErrorRate,
                                                      false);

      ApplyLinkState(lr, postMacDrop, appliedJitter, delay);
      lr.currentRawLoss = sampleOpt.has_value() ? rawPacketErrorRate : phyPacketErrorRate;
      lr.currentPhyLoss = phyPacketErrorRate;
      lr.currentRxPowerDbm = rxPowerDbm;
      lr.currentLossFromPathloss = fromPathloss;
      lr.currentLossModel = lossModel + (rt->config.linkSimulation.macRetryEnabled ? "/mac_retry" : "");
    }
  }

  if (rt->config.globals.Ns3PairwiseImpairment())
  {
    UpdatePairwiseLinks(*rt);
  }
  else if (rt->config.globals.Ns3WifiAdhoc())
  {
    UpdateWifiAdhocLinks(*rt);
    LogWifiEndpointStats(*rt, t);
  }

  WriteLinkStateSharedSnapshot(*rt, t);

  if (rt->ttyUi)
  {
    RenderStatusPanel(*rt, t);
  }
  else
  {
    if (rt->config.globals.EndpointPairLinkImpairment() ||
        rt->config.globals.Ns3WifiAdhoc())
    {
      for (const auto &pl : rt->pairLinks)
      {
        LogPairLinkState(t, pl, rt->verbose);
      }
    }
    else
    {
      for (const auto &lr : rt->dynamicLinks)
      {
        LogLinkState(t, lr, rt->verbose);
      }
    }
  }

  SchedulePeriodicUpdates(*rt);
}

void
SchedulePeriodicUpdates(TopologyRuntime &rt)
{
  const Time tick = ParseTimeOrDefault(rt.config.globals.tick, MilliSeconds(200));
  Simulator::Schedule(tick, &OnPeriodicUpdate, &rt);
}

} // namespace
