// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "./Main.sol";
import "hardhat/console.sol";

interface IData {
    function initializeContinents() external;

    function getContinentOwner(uint256 continent) external view returns (uint8);

    function getContinentBonus(uint256 continent) external view returns (uint8);

    function pushToTerritories(uint8[] memory territories) external;

    function addTroopToTerritory(uint256 index) external;

    function updateContinents() external;

    function setControlsAddress(address controls) external;

    function getNeighbours(uint256 territory) external view returns (uint8[] memory);

    function getTerritoryOwner(uint256) external returns (uint8);

    function getTroopCount(uint256 territory) external view returns (uint256);

    function removeTroopFromTerritory(uint256 index) external;

    function changeOwner(uint256 territory, uint8 newOwner) external;

    function resetData() external;
}

contract Controls is IControls, VRFConsumerBaseV2 {
    event CurrentPlayer(address indexed player);
    event ReceivedMain(address indexed main);
    event PlayerDeploying(address indexed player);
    event PlayerAttacking(address indexed player);
    event PlayerFortifying(address indexed player);
    event DiceRolled();
    event RollingDice(uint256 indexed s_requestId);
    event GameOver(address indexed winner);
    event TransferTroopsAvailable(uint256 indexed territoryBeingAttacked);
    event AttackerDie(uint256 indexed die);
    event DefenderDie(uint256 indexed die);

    // enums

    enum mainAddressSent {
        TRUE,
        FALSE
    }

    // Chainlink VRF Variables
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    uint64 private immutable i_subscriptionId;
    bytes32 private immutable i_gasLane;
    uint32 private immutable i_callbackGasLimit;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;

    // variables
    uint256 s_recentAttackingArmies;
    uint256 s_recentDefendingArmies;
    uint8 s_recentTerritoryAttacking;
    uint8 s_recentTerritoryBeingAttacked;

    address private main_address;
    address private data_address;

    mainAddressSent public s_mainSet;
    uint256 public s_requestId;
    uint8 public s_troopsToDeploy;
    uint8 public s_playerTurn;

    address payable[] s_playersArray;
    uint256[] s_diceWords;

    bool s_attackSuccess;
    bool s_gameIsOver;

    constructor(
        address vrfCoordinatorV2,
        uint64 subscriptionId,
        bytes32 gasLane,
        uint32 callbackGasLimit,
        address data
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_subscriptionId = subscriptionId;
        i_gasLane = gasLane;
        i_callbackGasLimit = callbackGasLimit;
        data_address = data;
        s_mainSet = mainAddressSent.FALSE;
        s_playerTurn = 3;
        s_troopsToDeploy;
        s_attackSuccess = false;
        s_gameIsOver = false;
    }

    modifier onlyMain() {
        require(msg.sender == main_address);
        _;
    }

    modifier gameIsOver() {
        require(s_gameIsOver == true);
        _;
    }

    function set_main_address(address main) external override {
        require(s_mainSet == mainAddressSent.FALSE);
        emit ReceivedMain(main);
        main_address = main;
        s_mainSet = mainAddressSent.TRUE;
        IData(data_address).setControlsAddress(address(this));
    }

    function set_players(address payable[] memory players) external override onlyMain {
        s_playersArray = players;
        IData(data_address).initializeContinents();
        next_player();
    }

    function next_player() private {
        s_playerTurn++;
        if (s_playerTurn == s_playersArray.length) {
            s_playerTurn = 0;
        }
        IData(data_address).updateContinents();
        s_troopsToDeploy = 0;
        for (uint256 c; c < 6; c++) {
            if (IData(data_address).getContinentOwner(c) == s_playerTurn) {
                s_troopsToDeploy += IData(data_address).getContinentBonus(c);
            }
        }

        uint8 totalTerritories;
        for (uint256 i; i < 42; i++) {
            if (IData(data_address).getTerritoryOwner(i) == s_playerTurn) {
                totalTerritories++;
            }
        }
        if (totalTerritories < 9) {
            s_troopsToDeploy += 3;
        } else {
            s_troopsToDeploy += totalTerritories / 3;
        }
    }

    function deploy_control(uint8 amountToDeploy, uint8 location) external override onlyMain returns (bool) {
        require(IData(data_address).getTerritoryOwner(location) == s_playerTurn, "You do not own this territory");
        emit PlayerDeploying(s_playersArray[s_playerTurn]);
        for (uint256 i; i < amountToDeploy; i++) {
            IData(data_address).addTroopToTerritory(location);
        }
        s_troopsToDeploy -= amountToDeploy;
        if (s_troopsToDeploy == 0) {
            return false; // returns false if all troops have not been deployed
        }
        return true;
    }

    function attack_control(
        uint8 territoryOwned,
        uint8 territoryAttacking,
        uint16 attackingArmies // could
    ) external override onlyMain {
        require(
            validate_attackable(territoryOwned, territoryAttacking),
            "Territory you are trying to attack is not a neighbour!"
        );
        require(
            (attackingArmies < IData(data_address).getTroopCount(territoryOwned)) && (attackingArmies > 0),
            "You cannot attack with that many troops!"
        );
        emit PlayerAttacking(s_playersArray[s_playerTurn]);

        uint256 defendingArmies = IData(data_address).getTroopCount(territoryAttacking);
        if (defendingArmies >= 2) {
            defendingArmies = 2;
        } else {
            defendingArmies = 1;
        }
        uint8 num_words = getArmies(attackingArmies, defendingArmies); // attackingArmies, defendingArmies not returning correct numbers
        console.log("num words:", num_words);
        s_recentTerritoryAttacking = territoryOwned;
        s_recentTerritoryBeingAttacked = territoryAttacking;
        s_recentAttackingArmies = attackingArmies;
        s_recentDefendingArmies = defendingArmies;
        diceRoller(num_words);

        // 1. Player clicks on their own territory
        // 2. Player clicks on enemy territory.
        // 3. Player chooses how many troops to attack with.
        // 4. Player attacks
    }

    function battle(
        uint256 attackingArmies,
        uint256 defendingArmies,
        uint256 territoryAttacking,
        uint256 territoryBeingAttacked,
        uint256[] memory randomWords
    ) private {
        uint256[] memory attackerRolls = new uint256[](attackingArmies);
        uint256[] memory defenderRolls = new uint256[](defendingArmies);
        for (uint256 i; i < (attackingArmies + defendingArmies); ++i) {
            if (i < attackingArmies) {
                attackerRolls[i] = randomWords[i] % 6;
            } else {
                defenderRolls[i - attackingArmies] = randomWords[i] % 6;
            }
        }
        // Sorting the two rolls arrays
        insertionSort(attackerRolls);
        insertionSort(defenderRolls);

        for (uint256 i; i < attackerRolls.length; ++i) {}
        for (uint256 i; i < defenderRolls.length; ++i) {}

        uint256 attacks; // either 1 or 2
        if (attackingArmies > defendingArmies) {
            attacks = defendingArmies;
        } else {
            attacks = attackingArmies;
        }
        for (uint256 i; i < attacks; ++i) {
            console.log("attacker rolls", attackerRolls[i]);
            console.log("defender rolls", defenderRolls[i]);
            if (attackerRolls[i] > defenderRolls[i]) {
                // 3 v 1 , 2 v 1 , 1 v 1, 2 v 2, 2 v 1, 1 v 1 //
                // attacker wins, defender dies
                emit AttackerDie(attackerRolls[i]);
                emit DefenderDie(defenderRolls[i]);
                IData(data_address).removeTroopFromTerritory(territoryBeingAttacked);
                if (
                    // Attacker has killed all troops in the defending territory
                    IData(data_address).getTroopCount(territoryBeingAttacked) == 0
                ) {
                    // Territory now becomes Attackers
                    IData(data_address).changeOwner(territoryBeingAttacked, s_playerTurn);
                    IData(data_address).removeTroopFromTerritory(territoryAttacking);
                    IData(data_address).addTroopToTerritory(territoryBeingAttacked);
                    // Attacker can select how many troops he wants to deploy to territory
                    s_attackSuccess = true;
                    uint256 defeatedPlayer = IData(data_address).getTerritoryOwner(territoryBeingAttacked);
                    if (getTotalTroops(defeatedPlayer) == 0) {
                        // if that was the last armies of the player
                        killPlayer(defeatedPlayer); // player is removed from the game
                    }
                    if (s_playersArray.length == 1) {
                        gameOver();
                        s_gameIsOver = true;
                    } else {
                        emit TransferTroopsAvailable(territoryBeingAttacked);
                    }
                }
            } else {
                // defender wins
                emit AttackerDie(attackerRolls[i]);
                emit DefenderDie(defenderRolls[i]);
                IData(data_address).removeTroopFromTerritory(territoryAttacking);
            }
        }
    }

    // This is a function that is executed when a button is clicked.
    function troopTransferAfterAttack(uint256 amountOfTroops) public {
        require(s_attackSuccess);
        require(s_playersArray[s_playerTurn] == msg.sender);
        require(
            amountOfTroops < IData(data_address).getTroopCount(s_recentTerritoryAttacking) && (amountOfTroops > 0),
            "You cannot move that amount of troops!"
        );

        for (uint256 i; i < amountOfTroops; i++) {
            IData(data_address).addTroopToTerritory(s_recentTerritoryBeingAttacked);
            IData(data_address).removeTroopFromTerritory(s_recentTerritoryAttacking);
        }
        s_attackSuccess = false;
    }

    function diceRoller(uint32 num_words) private {
        s_requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            num_words
        );
        emit RollingDice(s_requestId);
    }

    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        s_diceWords = randomWords;
        emit DiceRolled();
        battle(
            s_recentAttackingArmies,
            s_recentDefendingArmies,
            s_recentTerritoryAttacking,
            s_recentTerritoryBeingAttacked,
            randomWords
        );
    }

    function transferTroops(
        uint8 territoryMovingFrom,
        uint8 territoryMovingTo,
        uint256 troopsMoving
    ) public {
        require(
            (troopsMoving < IData(data_address).getTroopCount(territoryMovingFrom)) && (troopsMoving > 0),
            "You cannot move that amount of troops!"
        );

        for (uint256 i; i < troopsMoving; i++) {
            IData(data_address).addTroopToTerritory(territoryMovingTo);
            IData(data_address).removeTroopFromTerritory(territoryMovingFrom);
        }
    }

    function fortify_control(
        uint8 territoryMovingFrom,
        uint8 territoryMovingTo,
        uint256 troopsMoving
    ) external override onlyMain returns (bool) {
        //need to add parameters
        emit PlayerFortifying(s_playersArray[s_playerTurn]);
        require(
            validateFortifiable(territoryMovingFrom, territoryMovingTo),
            "Territory you are trying move troops to is not one of your neighbours!"
        );
        transferTroops(territoryMovingFrom, territoryMovingTo, troopsMoving);

        next_player();
        return true;
    }

    function validate_owner(uint8 territory_clicked) internal returns (bool) {
        uint8 territory_owner = IData(data_address).getTerritoryOwner(territory_clicked);
        if (territory_owner == s_playerTurn) {
            return true;
        } else {
            return false;
        }
    }

    function validateFortifiable(uint8 territoryMovingFrom, uint8 territoryMovingTo) internal returns (bool) {
        require(IData(data_address).getTroopCount(territoryMovingFrom) > 1, "You must have more than 1 troop to move!");
        require(
            validate_owner(territoryMovingFrom) && validate_owner(territoryMovingTo),
            "You must own both territories to move troops!"
        );
        uint8[] memory neighbours = IData(data_address).getNeighbours(territoryMovingFrom);
        for (uint256 i; i < 6; i++) {
            if ((territoryMovingTo == neighbours[i])) {
                return true;
            }
        }
        return false;
    }

    function validate_attackable(uint8 territoryOwned, uint8 territoryAttacking) internal returns (bool) {
        require(
            IData(data_address).getTroopCount(territoryOwned) > 1,
            "You must have at least 1 troop remaining in your territory to attack!"
        );
        require(!validate_owner(territoryAttacking), "You cannot attack your own territory!"); //checks if the player owns the territory they are trying to attack
        uint8[] memory neighbours = IData(data_address).getNeighbours(territoryOwned);
        for (uint256 i; i < 6; i++) {
            if ((territoryAttacking == neighbours[i])) {
                return true;
            }
        }
        return false;
    }

    function getArmies(uint256 attackingArmies, uint256 defendingArmies) private pure returns (uint8) {
        uint8 num_words;
        if (attackingArmies == 3) {
            num_words = 3;
        } else if (attackingArmies == 2) {
            num_words = 2;
        } else {
            num_words = 1;
        }
        if (defendingArmies == 2) {
            num_words += 2;
        } else {
            num_words += 1;
        }
        return num_words;
    }

    function gameOver() public gameIsOver {
        address winner = s_playersArray[s_playerTurn];
        emit GameOver(winner);
        (bool success, ) = main_address.call(abi.encodeWithSignature("payWinner(address)", winner));
        require(success, "call to main failed");
        IData(data_address).resetData();
        resetControls();
    }

    function resetControls() private {
        s_playerTurn = 3;
        s_troopsToDeploy;
        s_attackSuccess = false;
        s_gameIsOver = false;
        s_playersArray = new address payable[](0);
    }

    function add_troop_to_territory(uint256 index) external override onlyMain {
        IData(data_address).addTroopToTerritory(index);
    }

    function killPlayer(uint256 deadPlayer) private {
        delete s_playersArray[deadPlayer];
    }

    function getTotalTroops(uint256 player) public returns (uint256) {
        uint256 totalTroops;
        for (uint256 i; i < 42; i++) {
            if (IData(data_address).getTerritoryOwner(i) == player) {
                totalTroops += IData(data_address).getTroopCount(i);
            }
        }
        return totalTroops;
    }

    function get_territory_owner(uint256 j) external override onlyMain returns (uint256) {
        return IData(data_address).getTerritoryOwner(j);
    }

    function get_troops_to_deploy() public view override returns (uint8) {
        return s_troopsToDeploy;
    }

    function getPlayerTurn() public view override returns (address) {
        return s_playersArray[s_playerTurn];
    }

    function getRequestId() public view returns (uint256) {
        return s_requestId;
    }

    function push_to_territories(uint8[] memory territory) external onlyMain {
        IData(data_address).pushToTerritories(territory);
    }

    function getAttackStatus() public view override returns (bool) {
        return s_attackSuccess;
    }

    function insertionSort(uint256[] memory arr) private pure {
        uint256 i;
        uint256 key;
        int256 j;
        for (i = 1; i < arr.length; ++i) {
            key = arr[i];
            j = int256(i - 1);
            while (j >= 0 && arr[uint256(j)] < key) {
                arr[uint256(j + 1)] = arr[uint256(j)];
                --j;
            }
            arr[uint256(j + 1)] = key;
        }
    }
}
