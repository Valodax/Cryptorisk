// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";
import "hardhat/console.sol";

/**@title Cryptorisk Main Contract
 * @author Michael King and Mitchell Spencer
 * @dev Implements the Chainlink VRF V2
 */

interface IControls {
    function set_players(address payable[] memory) external;

    function push_to_territories(uint8 playerAwarded) external;

    function get_territory_owner(uint256) external returns (uint256);

    function add_troop_to_territory(uint256) external;

    function set_main_address(address main) external;

    function deploy_control(uint8 amountToDeploy, uint8 location) external returns (bool);

    function attack_control(
        uint8 territoryOwned,
        uint8 territoryAttacking,
        uint256 troopQuantity
    ) external;

    function fortify_control(
        uint8 territoryMovingFrom,
        uint8 territoryMovingTo,
        uint256 troopsMoving
    ) external returns (bool);

    function get_troops_to_deploy() external view returns (uint8);

    function getPlayerTurn() external view returns (address);

    function getAttackStatus() external view returns (bool);
}

contract Main is VRFConsumerBaseV2, AutomationCompatibleInterface {
    /* Type declarations */
    enum LobbyState {
        OPEN,
        CLOSED
    }
    enum GameState {
        DEPLOY,
        ATTACK,
        FORTIFY,
        INACTIVE
    }
    enum RandomState {
        RECEIVED,
        NOT
    }

    enum mainAddressSent {
        TRUE,
        FALSE
    }

    /* Variables */
    // Chainlink VRF Variables
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    uint64 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;

    // Setup Variables
    uint256 private immutable i_entranceFee;
    address private immutable controls_address;
    address private immutable data_address;
    uint8[] private playerSelection = [0, 1, 2, 3];
    uint8[4] private territoriesAssigned = [0, 0, 0, 0]; // Used to track if player receives enough territory.
    GameState public s_gameState;
    LobbyState public s_lobbyState;
    RandomState public s_hasRandomWords;
    address payable[] public s_players;
    address public player_turn;
    mainAddressSent public s_mainSet;
    mapping(address => bool) public duplicateAddresses;
    address payable[] public s_lobbyEntrants;
    uint256 randomWordTerritories;
    uint256 randomWordTroops;
    uint256[] s_randomWordsArrayTerritories;
    uint256[] s_randomWordsArrayTroops;

    /* Events */
    event RequestedRandomness(uint256 indexed requestId);
    event gotRandomness();
    event GameSetupComplete();
    event PlayerJoinedLobby(address indexed player);
    event GameStarting();
    event WinnerSentFunds(address indexed player);
    event MainReset();

    /* Errors */
    error Transfer___Failed();

    constructor(
        address vrfCoordinatorV2,
        uint64 subscriptionId,
        bytes32 gasLane, // keyHash
        uint32 callbackGasLimit,
        uint256 entranceFee,
        address controls,
        address data
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_subscriptionId = subscriptionId;
        i_gasLane = gasLane;
        i_callbackGasLimit = callbackGasLimit;
        i_entranceFee = entranceFee;
        s_lobbyState = LobbyState.OPEN;
        s_gameState = GameState.INACTIVE;
        s_mainSet = mainAddressSent.FALSE;
        controls_address = controls;
        data_address = data;
    }

    /* Modifiers */

    modifier onlyPlayer() {
        require(msg.sender == IControls(controls_address).getPlayerTurn());
        _;
    }

    modifier onlyControls() {
        require(msg.sender == controls_address);
        _;
        //testttt
    }

    /* Functions */

    function enterLobby() public payable {
        require(msg.value >= i_entranceFee, "Send More to Enter Lobby");
        require(s_lobbyState == LobbyState.OPEN, "Lobby is full"); // require or if statement?
        require(duplicateAddresses[msg.sender] == false, "You've already entered the game!");
        s_players.push(payable(msg.sender));
        s_lobbyEntrants.push(payable(msg.sender));
        emit PlayerJoinedLobby(msg.sender);
        duplicateAddresses[msg.sender] = true;
        if (s_players.length == 4) {
            s_lobbyState = LobbyState.CLOSED;
            emit GameStarting();
            requestRandomness();
        }
    }

    // call this function as soon as contract is deployed
    function setMainAddress() public {
        require(s_mainSet == mainAddressSent.FALSE, "Controls contract has already received Main address");
        IControls(controls_address).set_main_address(address(this));
        s_mainSet = mainAddressSent.TRUE;
    }

    function requestRandomness() private {
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            2
        );
        emit RequestedRandomness(requestId);
    }

    function randomWordsArrayTerritories() public {
        uint256[] memory territories = new uint256[](42);
        uint256 randomLength = numDigits(randomWordTerritories);
        uint256 num;
        uint8 index;
        uint256 i;
        while (i < 42) {
            num = getDigitAtIndex(randomWordTerritories, index);
            if (num < 8) {
                territories[i] = (num % 4);
                //s_randomWordsArrayTerritories.push(num % 4);
                i++;
            }
            if (index == randomLength - 1) {
                index = 0;
            }
            index++;
        }
        assignTerritory(territories);
        // s_randomWordsArrayTerritories = territories;
    }

    function randomWordsArrayTroops() public {
        uint256[] memory troops = new uint256[](78);
        uint256 randomLength = numDigits(randomWordTroops);
        uint256 num;
        uint256 num2;
        uint8 index;
        uint8 i;
        while (i < 78) {
            num = getDigitAtIndex(randomWordTroops, index);
            num2 = getDigitAtIndex(randomWordTroops, index + 1);
            num = num + num2 * 10;
            troops[i] = num;
            i++;
            if (index == randomLength - 2) {
                index = 0;
            }
            index++;
        }
        assignTroops(troops);
        // s_randomWordsArrayTroops = troops;
    }

    function checkUpkeep(
        bytes memory /*checkData*/
    )
        public
        override
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        bool lobbyClosed = (s_lobbyState == LobbyState.CLOSED);
        bool hasPlayers = (s_players.length == 4);
        bool hasBalance = address(this).balance > 0;
        bool hasRandomness = (s_hasRandomWords == RandomState.RECEIVED);
        upkeepNeeded = (lobbyClosed && hasPlayers && hasBalance && hasRandomness);
    }

    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        randomWordsArrayTerritories();
        randomWordsArrayTroops();
        emit GameSetupComplete();
        s_gameState = GameState.DEPLOY;
        IControls(controls_address).set_players(s_players);
    }

    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        emit gotRandomness();
        randomWordTerritories = randomWords[0];
        randomWordTroops = randomWords[1];
    }

    /**
     * Function receives array of 42 random words which are then used to assign each territory (0-41) an owner (0-3).
     * Mutates a globally declared array s_territories.
     */

    function remove(uint256 index) public {
        playerSelection[index] = playerSelection[playerSelection.length - 1];
        playerSelection.pop();
    }

    function assignTerritory(uint256[] memory territories) private {
        // Eligible players to be assigned territory, each is popped until no players left to receive.
        uint8 territoryCap = 10; // Initial cap is 10, moves up to 11 after two players assigned 10.
        uint8 remainingPlayers = 4; // Ticks down as players hit their territory cap
        uint256 indexAssignedTerritory; // Index of playerSelection that contains a list of eligible players to receive territory.
        uint8 playerAwarded; // Stores the player to be awarded territory, for pushing into the s_territories array.'
        for (uint256 i; i < territories.length; i++) {
            indexAssignedTerritory = territories[i] % remainingPlayers; // Calculates which index from playerSelection will receive the territory
            playerAwarded = playerSelection[indexAssignedTerritory]; // Player to be awarded territory
            IControls(controls_address).push_to_territories(playerAwarded);
            territoriesAssigned[playerAwarded]++;
            if (territoriesAssigned[playerAwarded] == territoryCap) {
                delete playerSelection[indexAssignedTerritory]; // Removes awarded player from the array upon hitting territory cap.
                remove(indexAssignedTerritory);
                remainingPlayers--;
                if (remainingPlayers == 2) {
                    territoryCap = 11; // Moves up instead of down, to remove situation where the cap goes down and we have players already on the cap then receiving too much territory.
                }
            }
        }
    }

    function assignTroops(uint256[] memory troops) private {
        uint256 randomWordsIndex;
        // s_territories.length == 42
        // playerTerritoryIndexes.length == 10 or 11
        for (uint256 i; i < 4; i++) {
            uint256[] memory playerTerritoryIndexes = new uint256[](territoriesAssigned[i]); // Initializes array of indexes for territories owned by player i
            uint256 index = 0;
            for (uint256 j = 0; j < 42; j++) {
                if (IControls(controls_address).get_territory_owner(j) == i) {
                    playerTerritoryIndexes[index++] = j;
                }
            }
            for (uint256 j; j < 30 - territoriesAssigned[i]; j++) {
                uint256 territoryAssignedTroop = troops[randomWordsIndex++] % territoriesAssigned[i];
                IControls(controls_address).add_troop_to_territory(playerTerritoryIndexes[territoryAssignedTroop]);
            }
        }
    }

    function deploy(uint8 amountToDeploy, uint8 location) public onlyPlayer {
        require(s_gameState == GameState.DEPLOY, "It is currently not deploy phase!");
        require(
            amountToDeploy <= IControls(controls_address).get_troops_to_deploy(),
            "You do not have that many troops to deploy!"
        );
        bool troopsLeft = IControls(controls_address).deploy_control(amountToDeploy, location);
        if (troopsLeft == false) {
            s_gameState = GameState.ATTACK;
        }
    }

    function attack(
        uint8 useThisTerritory,
        uint8 toAttackThisTerritory,
        uint256 withTroopQuantity
    ) public onlyPlayer {
        require(IControls(controls_address).getAttackStatus() == false);
        require(s_gameState == GameState.ATTACK, "It is currently not attack phase!");
        IControls(controls_address).attack_control(useThisTerritory, toAttackThisTerritory, withTroopQuantity);
    }

    // player clicks this button when they have finished attacking
    function finishAttack() public onlyPlayer {
        require(IControls(controls_address).getAttackStatus() == false);
        s_gameState = GameState.FORTIFY;
    }

    function fortify(
        uint8 territoryMovingFrom,
        uint8 territoryMovingTo,
        uint256 troopsMoving
    ) public onlyPlayer {
        require(s_gameState == GameState.FORTIFY, "It is currently not fortify phase!");
        require(
            IControls(controls_address).fortify_control(territoryMovingFrom, territoryMovingTo, troopsMoving) == true,
            "Your fortification attempt failed"
        );
        s_gameState = GameState.DEPLOY;
    }

    function payWinner(address winner) public onlyControls returns (bool) {
        (bool success, ) = winner.call{value: address(this).balance}("");
        if (!success) {
            revert Transfer___Failed();
        }
        emit WinnerSentFunds(winner);
        resetMain();
        return success;
    }

    /** Pure Functions */

    function numDigits(uint256 number) public pure returns (uint256) {
        uint256 digits;
        //if (number < 0) digits = 1; // enable this line if '-' counts as a digit
        while (number != 0) {
            number /= 10;
            digits++;
        }
        return digits;
    }

    function getDigitAtIndex(uint256 n, uint8 index) public pure returns (uint256) {
        return (n / (10**index)) % 10;
    }

    /** Getter Functions */

    function getRandomWordsArrayTerritories() public view returns (uint256[] memory) {
        return s_randomWordsArrayTerritories;
    }

    function getRandomWordsArrayTroops() public view returns (uint256[] memory) {
        return s_randomWordsArrayTroops;
    }

    function getRandomWordsArrayIndexTerritories(uint256 index) public view returns (uint256) {
        return s_randomWordsArrayTerritories[index];
    }

    function getRandomWordsArrayIndexTroops(uint256 index) public view returns (uint256) {
        return s_randomWordsArrayTroops[index];
    }

    function getSubscriptionId() public view returns (uint64) {
        return i_subscriptionId;
    }

    function getGasLane() public view returns (bytes32) {
        return i_gasLane;
    }

    function getCallbackGasLimit() public view returns (uint32) {
        return i_callbackGasLimit;
    }

    function getRequestConfirmations() public pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getPlayer(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getNumberOfPlayers() public view returns (uint256) {
        return s_players.length;
    }

    function getEntranceFee() public view returns (uint256) {
        return i_entranceFee;
    }

    function getLobbyState() public view returns (LobbyState) {
        return s_lobbyState;
    }

    // Resets everything
    function resetMain() internal {
        s_lobbyState = LobbyState.OPEN;
        s_players = new address payable[](0);
        s_gameState = GameState.INACTIVE;
        territoriesAssigned = [0, 0, 0, 0];
        for (uint256 i; i < s_lobbyEntrants.length; i++) {
            duplicateAddresses[s_lobbyEntrants[i]] = false;
        }
        emit MainReset();
    }

    function insertionSort(uint8[4] memory arr) private pure {
        uint256 i;
        uint256 key;
        int256 j;
        for (i = 1; i < arr.length; i++) {
            key = arr[i];
            j = int256(i - 1);
            while (j >= 0 && arr[uint256(j)] < key) {
                arr[uint256(j + 1)] = arr[uint256(j)];
                j = j - 1;
            }
            arr[uint256(j + 1)] = uint8(key);
        }
    }
}
