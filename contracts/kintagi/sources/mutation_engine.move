/// Module: mutation_engine
/// The brain of Kintagi — evaluates trigger conditions and executes mutations.
/// Supports time-based, XP-threshold, and manual API-driven mutations.
/// Trigger rules are stored on-chain; their evaluation is trustless.
module kintagi::mutation_engine {

    use std::string::{Self, String};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::vec_map::{Self, VecMap};
    use kintagi::kintagi_nft::{Self, KintagiNFT};
    use kintagi::collection_manager::{Self, CreatorCap, MutatorCap};

    // ========== Error codes ==========
    const E_RULE_NOT_FOUND: u64 = 200;
    const E_CONDITION_NOT_MET: u64 = 201;
    const E_RULE_ALREADY_APPLIED: u64 = 202;
    const E_NOT_AUTHORIZED: u64 = 203;

    // ========== Trigger types (encoded as u8) ==========
    /// Trigger fires when NFT XP >= threshold
    const TRIGGER_XP_THRESHOLD: u8 = 1;
    /// Trigger fires when NFT level >= threshold
    const TRIGGER_LEVEL_THRESHOLD: u8 = 2;
    /// Trigger fires when current epoch >= target epoch (time-based)
    const TRIGGER_TIME_EPOCH: u8 = 3;
    /// Trigger fires when NFT mutation_count >= threshold
    const TRIGGER_MUTATION_COUNT: u8 = 4;
    /// Manual trigger — called by authorized mutator (API-driven)
    const TRIGGER_MANUAL: u8 = 5;

    // ========== Structs ==========

    /// A single mutation rule stored on-chain. When its condition is met,
    public struct MutationRule has key, store {
        id: UID,
        /// Which collection this rule belongs to
        collection_id: ID,
        /// Human-readable name: e.g. "Gold Skin Unlock"
        name: String,
        /// Trigger type (see constants above)
        trigger_type: u8,
        /// Numeric threshold for XP/level/count triggers. Epoch ms for time triggers.
        trigger_threshold: u64,
        /// The trait to mutate when condition is met
        target_trait_key: String,
        /// The new value to set for the trait
        target_trait_value: String,
        /// Optional new image URL (empty = no image change)
        new_image_url: String,
        /// Whether this rule can fire multiple times (false = one-shot)
        repeatable: bool,
        /// Created by (creator address)
        created_by: address,
    }

    /// Tracks which rules have already been applied to a specific NFT 
    public struct RuleApplicationRecord has key, store {
        id: UID,
        nft_id: address,
        rule_id: address,
        applied_at_epoch: u64,
    }

    // ========== Events ==========

    public struct RuleCreated has copy, drop {
        rule_id: address,
        collection_id: address,
        name: String,
        trigger_type: u8,
        trigger_threshold: u64,
    }

    public struct RuleExecuted has copy, drop {
        rule_id: address,
        nft_id: address,
        trait_key: String,
        new_value: String,
        trigger_type: u8,
        executor: address,
    }

    // ========== Rule management (creator-gated) ==========

    /// Create a new mutation rule for a collection
    public fun create_rule(
        cap: &CreatorCap,
        collection_id: ID,
        name: vector<u8>,
        trigger_type: u8,
        trigger_threshold: u64,
        target_trait_key: vector<u8>,
        target_trait_value: vector<u8>,
        new_image_url: vector<u8>,
        repeatable: bool,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let rule = MutationRule {
            id: object::new(ctx),
            collection_id,
            name: string::utf8(name),
            trigger_type,
            trigger_threshold,
            target_trait_key: string::utf8(target_trait_key),
            target_trait_value: string::utf8(target_trait_value),
            new_image_url: string::utf8(new_image_url),
            repeatable,
            created_by: tx_context::sender(ctx),
        };

        let rule_id = object::uid_to_address(&rule.id);

        event::emit(RuleCreated {
            rule_id,
            collection_id: object::id_to_address(&collection_id),
            name: rule.name,
            trigger_type,
            trigger_threshold,
        });

        // Rules are shared so anyone can attempt to trigger them (execution is still validated)
        transfer::share_object(rule);
    }

    // ========== Rule execution (public — trustless evaluation) ==========

    /// Evaluate and execute a rule against an NFT.
    /// Anyone can call this — the contract enforces the condition check.
    /// For TRIGGER_MANUAL, the caller must hold a MutatorCap.
    public fun execute_rule(
        rule: &MutationRule,
        nft: &mut KintagiNFT,
        ctx: &mut TxContext,
    ) {
        // Check trigger condition
        let condition_met = check_condition(rule, nft, ctx);
        assert!(condition_met, E_CONDITION_NOT_MET);

        // Apply the mutation
        kintagi_nft::set_trait(
            nft,
            *string::bytes(&rule.target_trait_key),
            *string::bytes(&rule.target_trait_value),
            ctx,
        );

        // Update image if specified
        let img = string::bytes(&rule.new_image_url);
        if (vector::length(img) > 0) {
            kintagi_nft::update_image(nft, *img, ctx);
        };

        // Record execution
        if (!rule.repeatable) {
            let record = RuleApplicationRecord {
                id: object::new(ctx),
                nft_id: kintagi_nft::nft_id(nft),
                rule_id: object::uid_to_address(&rule.id),
                applied_at_epoch: tx_context::epoch_timestamp_ms(ctx),
            };
            // Transfer record to NFT owner (sender is likely the owner or relayer)
            transfer::transfer(record, tx_context::sender(ctx));
        };

        event::emit(RuleExecuted {
            rule_id: object::uid_to_address(&rule.id),
            nft_id: kintagi_nft::nft_id(nft),
            trait_key: rule.target_trait_key,
            new_value: rule.target_trait_value,
            trigger_type: rule.trigger_type,
            executor: tx_context::sender(ctx),
        });
    }

    /// Execute a manual trigger (requires MutatorCap for authorization)
    public fun execute_manual_rule(
        _mutator_cap: &MutatorCap,
        rule: &MutationRule,
        nft: &mut KintagiNFT,
        ctx: &mut TxContext,
    ) {
        assert!(rule.trigger_type == TRIGGER_MANUAL, E_NOT_AUTHORIZED);

        kintagi_nft::set_trait(
            nft,
            *string::bytes(&rule.target_trait_key),
            *string::bytes(&rule.target_trait_value),
            ctx,
        );

        let img = string::bytes(&rule.new_image_url);
        if (vector::length(img) > 0) {
            kintagi_nft::update_image(nft, *img, ctx);
        };

        event::emit(RuleExecuted {
            rule_id: object::uid_to_address(&rule.id),
            nft_id: kintagi_nft::nft_id(nft),
            trait_key: rule.target_trait_key,
            new_value: rule.target_trait_value,
            trigger_type: TRIGGER_MANUAL,
            executor: tx_context::sender(ctx),
        });
    }

    // ========== Internal helpers ==========

    fun check_condition(rule: &MutationRule, nft: &KintagiNFT, ctx: &TxContext): bool {
        let t = rule.trigger_type;
        if (t == TRIGGER_XP_THRESHOLD) {
            kintagi_nft::get_xp(nft) >= rule.trigger_threshold
        } else if (t == TRIGGER_LEVEL_THRESHOLD) {
            kintagi_nft::get_level(nft) >= rule.trigger_threshold
        } else if (t == TRIGGER_TIME_EPOCH) {
            tx_context::epoch_timestamp_ms(ctx) >= rule.trigger_threshold
        } else if (t == TRIGGER_MUTATION_COUNT) {
            kintagi_nft::get_mutation_count(nft) >= rule.trigger_threshold
        } else if (t == TRIGGER_MANUAL) {
            true // manual trigger — authorization checked by MutatorCap
        } else {
            false
        }
    }

    // ========== View functions ==========

    public fun get_rule_name(r: &MutationRule): &String { &r.name }
    public fun get_trigger_type(r: &MutationRule): u8 { r.trigger_type }
    public fun get_trigger_threshold(r: &MutationRule): u64 { r.trigger_threshold }
    public fun get_target_trait(r: &MutationRule): &String { &r.target_trait_key }
    public fun get_target_value(r: &MutationRule): &String { &r.target_trait_value }
    public fun is_repeatable(r: &MutationRule): bool { r.repeatable }

    // ========== Trigger type constants (public accessors) ==========
    public fun trigger_xp(): u8 { TRIGGER_XP_THRESHOLD }
    public fun trigger_level(): u8 { TRIGGER_LEVEL_THRESHOLD }
    public fun trigger_time(): u8 { TRIGGER_TIME_EPOCH }
    public fun trigger_mutation_count(): u8 { TRIGGER_MUTATION_COUNT }
    public fun trigger_manual(): u8 { TRIGGER_MANUAL }
}
