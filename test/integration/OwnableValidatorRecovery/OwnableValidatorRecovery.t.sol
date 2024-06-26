// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import {ModuleKitHelpers, ModuleKitUserOp} from "modulekit/ModuleKit.sol";
import {MODULE_TYPE_EXECUTOR, MODULE_TYPE_VALIDATOR} from "modulekit/external/ERC7579.sol";

import {IEmailAccountRecovery} from "src/interfaces/IEmailAccountRecovery.sol";
import {OwnableValidatorRecoveryModule} from "src/modules/OwnableValidatorRecoveryModule.sol";
import {IZkEmailRecovery} from "src/interfaces/IZkEmailRecovery.sol";
import {GuardianStorage, GuardianStatus} from "src/libraries/EnumerableGuardianMap.sol";
import {OwnableValidator} from "src/test/OwnableValidator.sol";

import {OwnableValidatorBase} from "./OwnableValidatorBase.t.sol";

contract OwnableValidatorRecovery_Integration_Test is OwnableValidatorBase {
    using ModuleKitHelpers for *;
    using ModuleKitUserOp for *;

    OwnableValidator validator;
    OwnableValidatorRecoveryModule recoveryModule;
    address recoveryModuleAddress;

    function setUp() public override {
        super.setUp();

        validator = new OwnableValidator();
        recoveryModule = new OwnableValidatorRecoveryModule(
            address(zkEmailRecovery)
        );
        recoveryModuleAddress = address(recoveryModule);

        instance.installModule({
            moduleTypeId: MODULE_TYPE_VALIDATOR,
            module: address(validator),
            data: abi.encode(owner, recoveryModuleAddress)
        });
        // Install recovery module - configureRecovery is called on `onInstall`
        instance.installModule({
            moduleTypeId: MODULE_TYPE_EXECUTOR,
            module: recoveryModuleAddress,
            data: abi.encode(
                address(validator),
                guardians,
                guardianWeights,
                threshold,
                delay,
                expiry
            )
        });
    }

    function test_Recover_RotatesOwnerSuccessfully() public {
        address router = zkEmailRecovery.getRouterForAccount(accountAddress);

        // Accept guardian 1
        acceptGuardian(
            accountAddress,
            router,
            "Accept guardian request for 0x19F55F3fE4c8915F21cc92852CD8E924998fDa38",
            keccak256(abi.encode("nullifier 1")),
            accountSalt1,
            templateIdx
        );
        GuardianStorage memory guardianStorage1 = zkEmailRecovery.getGuardian(
            accountAddress,
            guardian1
        );
        assertEq(
            uint256(guardianStorage1.status),
            uint256(GuardianStatus.ACCEPTED)
        );
        assertEq(guardianStorage1.weight, uint256(1));

        // Accept guardian 2
        acceptGuardian(
            accountAddress,
            router,
            "Accept guardian request for 0x19F55F3fE4c8915F21cc92852CD8E924998fDa38",
            keccak256(abi.encode("nullifier 1")),
            accountSalt2,
            templateIdx
        );
        GuardianStorage memory guardianStorage2 = zkEmailRecovery.getGuardian(
            accountAddress,
            guardian2
        );
        assertEq(
            uint256(guardianStorage2.status),
            uint256(GuardianStatus.ACCEPTED)
        );
        assertEq(guardianStorage2.weight, uint256(1));

        // Time travel so that EmailAuth timestamp is valid
        vm.warp(12 seconds);
        // handle recovery request for guardian 1
        handleRecovery(
            accountAddress,
            newOwner,
            recoveryModuleAddress,
            router,
            "Recover account 0x19F55F3fE4c8915F21cc92852CD8E924998fDa38 to new owner 0x7240b687730BE024bcfD084621f794C2e4F8408f using recovery module 0x08e2f9BefEb86008a498ba29C3a70d1CF15fCdA5",
            keccak256(abi.encode("nullifier 2")),
            accountSalt1,
            templateIdx
        );
        IZkEmailRecovery.RecoveryRequest
            memory recoveryRequest = zkEmailRecovery.getRecoveryRequest(
                accountAddress
            );
        assertEq(recoveryRequest.executeAfter, 0);
        assertEq(recoveryRequest.currentWeight, 1);

        // handle recovery request for guardian 2
        uint256 executeAfter = block.timestamp + delay;
        handleRecovery(
            accountAddress,
            newOwner,
            recoveryModuleAddress,
            router,
            "Recover account 0x19F55F3fE4c8915F21cc92852CD8E924998fDa38 to new owner 0x7240b687730BE024bcfD084621f794C2e4F8408f using recovery module 0x08e2f9BefEb86008a498ba29C3a70d1CF15fCdA5",
            keccak256(abi.encode("nullifier 2")),
            accountSalt2,
            templateIdx
        );
        recoveryRequest = zkEmailRecovery.getRecoveryRequest(accountAddress);
        assertEq(recoveryRequest.executeAfter, executeAfter);
        assertEq(recoveryRequest.currentWeight, 2);

        // Time travel so that the recovery delay has passed
        vm.warp(block.timestamp + delay);

        // Complete recovery
        IEmailAccountRecovery(router).completeRecovery();

        recoveryRequest = zkEmailRecovery.getRecoveryRequest(accountAddress);
        address updatedOwner = validator.owners(accountAddress);

        assertEq(recoveryRequest.executeAfter, 0);
        assertEq(recoveryRequest.currentWeight, 0);
        assertEq(updatedOwner, newOwner);
    }

    function test_OnUninstall_DeInitsStateSuccessfully() public {
        // configure and complete an entire recovery request
        test_Recover_RotatesOwnerSuccessfully();
        address router = zkEmailRecovery.computeRouterAddress(
            keccak256(abi.encode(accountAddress))
        );

        // Uninstall module
        vm.prank(accountAddress);
        instance.uninstallModule(
            MODULE_TYPE_EXECUTOR,
            recoveryModuleAddress,
            ""
        );
        vm.stopPrank();

        bool isModuleInstalled = instance.isModuleInstalled(
            MODULE_TYPE_EXECUTOR,
            recoveryModuleAddress,
            ""
        );
        assertFalse(isModuleInstalled);

        // assert that recovery config has been cleared successfully
        IZkEmailRecovery.RecoveryConfig memory recoveryConfig = zkEmailRecovery
            .getRecoveryConfig(accountAddress);
        assertEq(recoveryConfig.recoveryModule, address(0));
        assertEq(recoveryConfig.delay, 0);
        assertEq(recoveryConfig.expiry, 0);

        // assert that the recovery request has been cleared successfully
        IZkEmailRecovery.RecoveryRequest
            memory recoveryRequest = zkEmailRecovery.getRecoveryRequest(
                accountAddress
            );
        assertEq(recoveryRequest.executeAfter, 0);
        assertEq(recoveryRequest.executeBefore, 0);
        assertEq(recoveryRequest.currentWeight, 0);
        assertEq(recoveryRequest.subjectParams.length, 0);

        // assert that guardian storage has been cleared successfully for guardian 1
        GuardianStorage memory guardianStorage1 = zkEmailRecovery.getGuardian(
            accountAddress,
            guardian1
        );
        assertEq(
            uint256(guardianStorage1.status),
            uint256(GuardianStatus.NONE)
        );
        assertEq(guardianStorage1.weight, uint256(0));

        // assert that guardian storage has been cleared successfully for guardian 2
        GuardianStorage memory guardianStorage2 = zkEmailRecovery.getGuardian(
            accountAddress,
            guardian2
        );
        assertEq(
            uint256(guardianStorage2.status),
            uint256(GuardianStatus.NONE)
        );
        assertEq(guardianStorage2.weight, uint256(0));

        // assert that guardian config has been cleared successfully
        IZkEmailRecovery.GuardianConfig memory guardianConfig = zkEmailRecovery
            .getGuardianConfig(accountAddress);
        assertEq(guardianConfig.guardianCount, 0);
        assertEq(guardianConfig.totalWeight, 0);
        assertEq(guardianConfig.threshold, 0);

        // assert that the recovery router mappings have been cleared successfully
        address accountForRouter = zkEmailRecovery.getAccountForRouter(router);
        address routerForAccount = zkEmailRecovery.getRouterForAccount(
            accountAddress
        );
        assertEq(accountForRouter, address(0));
        assertEq(routerForAccount, address(0));
    }
}
