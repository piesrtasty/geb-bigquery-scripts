DECLARE SAFEEngineAddress DEFAULT "0xcc88a9d330da1133df3a7bd823b95e52511a6962"; 
DECLARE SAFEManagerAddress DEFAULT "0xefe0b4ca532769a3ae758fd82e1426a03a94f185";
DECLARE ProxyRegistry DEFAULT "0x4678f0a6958e4d2bc4f1baf7bc52e8f3564f3fe4";
DECLARE DeployDate DEFAULT TIMESTAMP("2021-02-13 12:33:18+00");                # UTC date of deploy
DECLARE StartDate DEFAULT TIMESTAMP("2021-02-20 22:25:00+00");                 # UTC date when minting rewards started
DECLARE CutoffDate DEFAULT TIMESTAMP("2021-02-26 13:49:00+00");                # UTC date when minting rewards stopped
DECLARE CutoffBlock DEFAULT 11933211;                                          # Block when minting rewards stopped
DECLARE TokenOffered DEFAULT 1000e18;  # Number of FLX to distribute in total

# SAFE MANAGER Topic 
#DECLARE ModifyCollTopic DEFAULT "0x4a1d86235388d42bee8b26817295ba354feb351780a0005e14a02303ac302df8"; # SAFE Manager Topic
# SAFE Engine Topic 
DECLARE ModifyCollTopic DEFAULT "0x182725621f9c0d485fb256f86699c82616bd6e4670325087fd08f643cab7d917"; # SAFE Engine Topic
# SAFE Engine Topic 
DECLARE TransferCollDebtTopic DEFAULT "0x4b49cc19514005253f36d0517c21b92404f50cc0d9e0c070af00b96e296b0835"; #
# Build Proxy Topic
DECLARE BuildProxyTopic DEFAULT "0x7dc7288b571724fc253653469146b103ac7feda79b8525a533f3c008a94ba963";
# Constants
DECLARE NullAddress DEFAULT "0x0000000000000000000000000000000000000000";
DECLARE RewardRate DEFAULT TokenOffered / CAST(TIMESTAMP_DIFF(CutoffDate, StartDate, SECOND) AS NUMERIC);

# Subtracts deltaDebt from src, adds deltaDebt to dst
CREATE TEMP FUNCTION
  PARSE_TRANSFERSAFE_LOG(data STRING, topics ARRAY<STRING>)
  RETURNS STRUCT<`src` STRING, `dst` STRING, `deltaDebt` STRING>
  LANGUAGE js AS """
    var parsedEvent = {"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"collateralType","type":"bytes32"},{"indexed":true,"internalType":"address","name":"src","type":"address"},{"indexed":true,"internalType":"address","name":"dst","type":"address"},{"indexed":false,"internalType":"int256","name":"deltaCollateral","type":"int256"},{"indexed":false,"internalType":"int256","name":"deltaDebt","type":"int256"},{"indexed":false,"internalType":"uint256","name":"srcLockedCollateral","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"srcGeneratedDebt","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"dstLockedCollateral","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"dstGeneratedDebt","type":"uint256"}],"name":"TransferSAFECollateralAndDebt","type":"event"};
    return abi.decodeEvent(parsedEvent, data, topics, false);
"""
OPTIONS
  ( library="https://storage.googleapis.com/ethlab-183014.appspot.com/ethjs-abi.js" );

CREATE TEMP FUNCTION
  PARSE_MODSAFE_LOG(data STRING, topics ARRAY<STRING>)
  RETURNS STRUCT<`safe` STRING, `deltaDebt` STRING>
  LANGUAGE js AS """
    var parsedEvent = {"anonymous":false,"inputs":[{"indexed":true,"internalType":"bytes32","name":"collateralType","type":"bytes32"},{"indexed":true,"internalType":"address","name":"safe","type":"address"},{"indexed":false,"internalType":"address","name":"collateralSource","type":"address"},{"indexed":false,"internalType":"address","name":"debtDestination","type":"address"},{"indexed":false,"internalType":"int256","name":"deltaCollateral","type":"int256"},{"indexed":false,"internalType":"int256","name":"deltaDebt","type":"int256"},{"indexed":false,"internalType":"uint256","name":"lockedCollateral","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"generatedDebt","type":"uint256"},{"indexed":false,"internalType":"uint256","name":"globalDebt","type":"uint256"}],"name":"ModifySAFECollateralization","type":"event"};
    return abi.decodeEvent(parsedEvent, data, topics, false);
"""
OPTIONS
  ( library="https://storage.googleapis.com/ethlab-183014.appspot.com/ethjs-abi.js" );

# Exclusion list of addresses that wont receive rewards, lower case only!
WITH excluded_list AS (
  SELECT * FROM exclusions.excluded_safes as address),

/*
# Get all TransferSAFECollateralAndDebt events from SAFEEngine
deltaDebts_orig AS (
  SELECT *, PARSE_TRANSFERSAFE_LOG(data, topics) as transferSafe FROM `bigquery-public-data.crypto_ethereum.logs`
    WHERE block_timestamp >= DeployDate
      AND block_timestamp <= CutoffDate
      AND address = SAFEEngineAddress
      AND topics[offset(0)] = TransferCollDebtTopic
)

*/

# Get all ModifySAFECollateralization events from SAFEEngine
deltaDebts_orig AS (
  SELECT *, PARSE_MODSAFE_LOG(data, topics) as safeMod FROM `bigquery-public-data.crypto_ethereum.logs`
    WHERE block_timestamp >= DeployDate
      AND block_timestamp <= CutoffDate
      AND address = SAFEEngineAddress
      AND topics[offset(0)] = ModifyCollTopic
),


deltaDebts_raw AS (
  SELECT block_timestamp, block_number, log_index, safeMod.safe, safeMod.deltaDebt from deltaDebts_orig
),

# Cast delta debt to BIGNUMERIC
deltaDebts as (
  SELECT block_timestamp, block_number, log_index, safe as address, CAST(deltaDebt as BIGNUMERIC) as deltaDebt from deltaDebts_raw
),

# Keep only records after the start date
deltaDebts_after AS (
  SELECT * FROM deltaDebts
  WHERE block_timestamp >= StartDate
),

# Process records before the start date like if everyone prior to strtDate had deposited on start date
deltaDebts_before AS (
  SELECT StartDate AS block_timestamp, MAX(block_number) AS block_number, 0 AS log_index, address, SUM(deltaDebt) AS deltaDebt FROM deltaDebts
  WHERE block_timestamp <= StartDate
  GROUP BY address
),

# Merge records from before and after
deltaDebts_on_start AS (
  SELECT block_timestamp, block_number, log_index, address, deltaDebt FROM deltaDebts_before
  UNION ALL
  SELECT block_timestamp, block_number, log_index, address, deltaDebt FROM deltaDebts_after
),

# Exclude the addresses from the exclusion list
deltaDebts_with_exclusions AS (
SELECT * FROM deltaDebts_on_start
WHERE address NOT IN (SELECT address FROM excluded_list)
),

# Add total_debt and individual debt balances
total_debt_and_balances AS (
  SELECT * ,
    # Add total_supply of lp token by looking at the balance of 0x0
    SUM(deltaDebt) OVER(ORDER BY block_timestamp, log_index) AS total_debt,
    # Debt balance of each individual address
    SUM(deltaDebt) OVER(PARTITION BY address ORDER BY block_timestamp, log_index) AS balance
  FROM deltaDebts_with_exclusions
),

# Add the delta_reward_per_token (increase in reward_per_token)
deltaDebts_delta_reward_per_token AS (
  SELECT *,
      COALESCE(CAST(TIMESTAMP_DIFF(block_timestamp, LAG(block_timestamp) OVER( ORDER BY block_timestamp, log_index), SECOND) AS NUMERIC), 0) AS delta_t,
      COALESCE(CAST(TIMESTAMP_DIFF(block_timestamp, LAG(block_timestamp) OVER( ORDER BY block_timestamp, log_index), SECOND) AS NUMERIC), 0) * RewardRate / (LAG(total_debt) OVER(ORDER BY block_timestamp, log_index)) AS delta_reward_per_token

  FROM total_debt_and_balances),

 deltaDebts_reward_per_token AS (
  SELECT *,
    SUM(delta_reward_per_token) OVER(ORDER BY block_timestamp, log_index) AS reward_per_token
  FROM deltaDebts_delta_reward_per_token
),

# Build a simple list of all paticipants
all_addresses AS (
  SELECT DISTINCT address FROM deltaDebts_reward_per_token
),

# Add cutoff events like if everybody had not debt on cutoff date. We need this to account for people that still have debt on cutoff date.
deltaDebts_with_cutoff_events AS (
  SELECT
    block_timestamp,
    log_index,
    address,
    balance,
    reward_per_token
  FROM deltaDebts_reward_per_token

  UNION ALL

  # Add the cutoff events
  SELECT
    CutoffDate AS block_timestamp,
    # Set it to the highest log index to be sure it comes last
    (SELECT MAX(log_index) FROM deltaDebts_reward_per_token) AS log_index,
    address AS address,
    # You unstaked so your balance is 0
    0 AS balance,
    # ⬇ reward_per_token on cutoff date                            ⬇ Time passed since the last update of reward_per_token                                                                              ⬇ latest total_supply
    (SELECT MAX(reward_per_token) FROM deltaDebts_reward_per_token) + COALESCE(CAST(TIMESTAMP_DIFF(CutoffDate, (SELECT MAX(block_timestamp) FROM deltaDebts_reward_per_token), SECOND) AS NUMERIC), 0) * RewardRate / (SELECT total_debt FROM deltaDebts_reward_per_token ORDER BY block_timestamp DESC LIMIT 1)
    AS reward_per_token
  FROM all_addresses
),

# Credit rewards, basically the earned() function from a staking contract
deltaDebts_earned AS (
  SELECT *,
    #                       ⬇ userRewardPerTokenPaid                                                                             ⬇ balance just before
    (reward_per_token - COALESCE(LAG(reward_per_token,1) OVER(PARTITION BY address ORDER BY block_timestamp, log_index), 0)) * COALESCE(LAG(balance) OVER(PARTITION BY address ORDER BY block_timestamp, log_index),0) AS earned,
  FROM deltaDebts_with_cutoff_events
),

# Sum up the earned event per address
final_reward_list AS (
  SELECT address, SUM(earned) AS reward
  FROM deltaDebts_earned
  GROUP BY address
),

safe_owners AS (
  SELECT block, safe as address, owner
  from `minting-incentives.safe_owners.safe_owners`
  WHERE
    block = CutoffBlock
),

#SELECT address, CAST(reward AS NUMERIC)/1e18 AS reward
#FROM final_reward_list
#WHERE
#  address != NullAddress AND
#  reward > 0
#ORDER BY reward DESC

reward_list as (
  SELECT safe_owners.owner as owner, CAST(final_reward_list.reward AS NUMERIC)/1e18 AS reward
  FROM final_reward_list INNER JOIN safe_owners USING (address)
  WHERE
    address != NullAddress AND
    reward > 0
)

# Output results
SELECT owner, SUM(reward)
FROM reward_list
GROUP BY owner
ORDER BY SUM(reward) DESC;