// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.30;

import {IHats} from "../../hats/IHats.sol";
import {IERC6551Registry} from "../../erc6551/IERC6551Registry.sol";
import {IHatsModuleFactory} from "../../hats/IHatsModuleFactory.sol";
import {IProxyFactory} from "../singletons/IProxyFactory.sol";
import {DecentHatsModuleUtils} from "../../../utilities/DecentHatsModuleUtils.sol";

interface IDecentHatsCreationModule {
    // --- Structs ---

    struct TopHatParams {
        string details;
        string imageURI;
    }

    struct AdminHatParams {
        string details;
        string imageURI;
        bool isMutable;
    }

    struct CreateTreeParams {
        IHats hatsProtocol;
        IERC6551Registry erc6551Registry;
        IHatsModuleFactory hatsModuleFactory;
        IProxyFactory proxyFactory;
        address keyValuePairs;
        address decentAutonomousAdminImplementation;
        address hatsAccountImplementation;
        address hatsElectionsEligibilityImplementation;
        TopHatParams topHat;
        AdminHatParams adminHat;
        DecentHatsModuleUtils.HatParams[] hats;
    }

    // --- State-Changing Functions ---

    function createAndDeclareTree(
        CreateTreeParams calldata treeParams_
    ) external;
}
