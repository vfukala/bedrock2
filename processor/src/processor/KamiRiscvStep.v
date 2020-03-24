Require Import String.
Require Import Coq.ZArith.ZArith.
Require Import coqutil.Z.Lia.
Require Import Coq.Lists.List. Import ListNotations.
Require Import Kami.Lib.Word.
Require Import Kami.Ex.IsaRv32 riscv.Spec.Decode.
Require Import riscv.Utility.Encode.
Require Import coqutil.Word.LittleEndian.
Require Import coqutil.Word.Properties.
Require Import coqutil.Map.Interface.
Require Import coqutil.Tactics.Tactics.
Require Import coqutil.Tactics.rdelta.
Require Import processor.KamiWord.
Require Import riscv.Utility.Utility.
Require Import riscv.Spec.Primitives.
Require Import riscv.Spec.MetricPrimitives.
Require Import riscv.Spec.Machine.
Require riscv.Platform.Memory.
Require Import riscv.Spec.PseudoInstructions.
Require Import riscv.Proofs.EncodeBound.
Require Import riscv.Proofs.DecodeEncode.
Require Import riscv.Platform.Run.
Require Import riscv.Utility.MkMachineWidth.
Require Import riscv.Utility.Monads. Import MonadNotations.
Require Import coqutil.Datatypes.PropSet.
Require Import riscv.Platform.RiscvMachine.
Require Import riscv.Platform.MetricRiscvMachine.
Require Import riscv.Platform.MinimalMMIO.
Require Import riscv.Platform.MetricMinimalMMIO.
Require Import riscv.Platform.FE310ExtSpec.

Require Import Kami.Syntax Kami.Semantics Kami.Tactics.
Require Import Kami.Ex.MemTypes Kami.Ex.SC Kami.Ex.SCMMInl Kami.Ex.SCMMInv.

Require Export processor.KamiProc.
Require Import processor.FetchOk processor.DecExecOk.

Local Open Scope Z_scope.

Lemma Npow2_lt:
  forall n m,
    (n < m)%nat -> (NatLib.Npow2 n < NatLib.Npow2 m)%N.
Proof.
  induction m; simpl; intros.
  - blia.
  - assert (n = m \/ n < m)%nat by blia.
    destruct H0.
    + subst.
      destruct (NatLib.Npow2 m) eqn:Hp.
      * exfalso; eapply NatLib.Npow2_not_zero; eauto.
      * blia.
    + specialize (IHm H0).
      destruct (NatLib.Npow2 m); blia.
Qed.

Lemma Npow2_le:
  forall n m,
    (n <= m)%nat -> (NatLib.Npow2 n <= NatLib.Npow2 m)%N.
Proof.
  induction m; simpl; intros.
  - assert (n = 0)%nat by blia.
    subst; simpl; blia.
  - assert (n = S m \/ n <= m)%nat by blia.
    destruct H0.
    + subst; reflexivity.
    + specialize (IHm H0).
      destruct (NatLib.Npow2 m); blia.
Qed.

Lemma bitSlice_range_ex:
  forall z n m,
    0 <= n <= m ->
    0 <= bitSlice z n m < 2 ^ (m - n).
Proof.
  intros.
  rewrite bitSlice_alt by blia.
  unfold bitSlice'.
  apply Z.mod_pos_bound.
  apply Z.pow_pos_nonneg; blia.
Qed.

Local Axiom TODO_word : False.

Lemma wordToN_wplus_distr:
  forall sz (w1 w2: Word.word sz),
    (wordToN w1 + wordToN w2 < NatLib.Npow2 sz)%N ->
    wordToN (w1 ^+ w2) = (wordToN w1 + wordToN w2)%N.
Proof.
  cbv [wplus wordBin]; intros.
  apply wordToN_NToWord_2; assumption.
Qed.

Section Equiv.
  Local Hint Resolve (@KamiWord.WordsKami width width_cases): typeclass_instances.

  Context {Registers: map.map Register word}
          {mem: map.map word byte}.

  Local Notation M := (free action result).
  Local Notation RiscvMachine := MetricRiscvMachine.
  Local Existing Instance MetricMinimalMMIO.IsRiscvMachine.
  Local Existing Instance MetricMinimalMMIOSatisfiesPrimitives.

  (** * Processor, software machine, and states *)

  Variable (instrMemSizeLg memSizeLg: Z).
  Hypotheses (Hinstr1: 3 <= instrMemSizeLg)
             (Hinstr2: instrMemSizeLg <= width - 2)
             (Hkmem1: 2 + instrMemSizeLg < memSizeLg)
             (Hkmem2: memSizeLg <= width)
             (* 16 used to be disjoint to MMIO addresses.
              * [Hkmem2] is meaningless assuming this [Hkmemdisj] 
              * but still having that in context ease some proofs. *)
             (Hkmemdisj: memSizeLg <= 16).
  Local Notation Hinstr := (conj Hinstr1 Hinstr2).

  Variable (memInit: Vec (ConstT (Bit BitsPerByte)) (Z.to_nat memSizeLg)).
  Definition kamiMemInit := ConstVector memInit.
  Local Definition kamiProc :=
    @KamiProc.proc instrMemSizeLg memSizeLg Hinstr kamiMemInit kami_FE310_AbsMMIO.
  Local Definition kamiStMk := @KamiProc.mk (Z.to_nat width)
                                            (Z.to_nat memSizeLg)
                                            (Z.to_nat instrMemSizeLg)
                                            rv32InstBytes rv32DataBytes rv32RfIdx.
  Local Notation kamiXAddrs := (kamiXAddrs instrMemSizeLg).
  Local Notation rv32Fetch :=
    (rv32Fetch (Z.to_nat width)
               (Z.to_nat instrMemSizeLg)
               (width_inst_valid Hinstr)).
  Local Notation RiscvXAddrsSafe :=
    (RiscvXAddrsSafe instrMemSizeLg memSizeLg (conj Hinstr1 Hinstr2)).

  Definition iset: InstructionSet := RV32I.

  (* redefine mcomp_sat to simplify for the case where no answer is returned *)
  Local Notation mcomp_sat_unit m initialL post :=
    (mcomp_sat m initialL (fun (_: unit) => post)).

  Context (Registers_ok: map.ok Registers)
          (mem_ok: map.ok mem).
  
  (** * Relations between Kami and riscv-coq *)

  Definition signedByteTupleToReg{n: nat}(v: HList.tuple byte n): word :=
    word.of_Z (BitOps.signExtend (8 * Z.of_nat n) (LittleEndian.combine n v)).

  Definition mmioLoadEvent(m: mem)(addr: word)(n: nat)(v: HList.tuple byte n): LogItem :=
    ((m, "MMIOREAD"%string, [addr]), (m, [signedByteTupleToReg v])).

  Definition mmioStoreEvent(m: mem)(addr: word)(n: nat)(v: HList.tuple byte n): LogItem :=
    ((m, "MMIOWRITE"%string, [addr; signedByteTupleToReg v]), (m, [])).

  (* common event between riscv-coq and Kami *)
  Inductive Event: Type :=
  | MMInputEvent(addr v: word)
  | MMOutputEvent(addr v: word).

  (* note: given-away and received memory has to be empty *)
  Inductive events_related: Event -> LogItem -> Prop :=
  | relate_MMInput: forall addr v,
      events_related (MMInputEvent addr v) ((map.empty, "MMIOREAD"%string, [addr]), (map.empty, [v]))
  | relate_MMOutput: forall addr v,
      events_related (MMOutputEvent addr v) ((map.empty, "MMIOWRITE"%string, [addr; v]), (map.empty, [])).

  Lemma events_related_mmioLoadEvent:
    forall addr1 v1 addr2 (v2: HList.tuple byte 4),
      addr1 = addr2 ->
      signExtend 32 (combine _ v2) = wordToZ v1 ->
      events_related (MMInputEvent addr1 v1) (MinimalMMIO.mmioLoadEvent addr2 v2).
  Proof.
    intros; subst.
    cbv [MinimalMMIO.mmioLoadEvent].
    cbv [MinimalMMIO.signedByteTupleToReg].
    change (8 * Z.of_nat 4) with 32; rewrite H0.
    cbv [word.of_Z word WordsKami wordW KamiWord.word kofZ].
    rewrite ZToWord_wordToZ.
    econstructor.
  Qed.

  Lemma events_related_mmioStoreEvent:
    forall addr1 v1 addr2 (v2: HList.tuple byte 4),
      addr1 = addr2 ->
      signExtend 32 (combine _ v2) = wordToZ v1 ->
      events_related (MMOutputEvent addr1 v1) (MinimalMMIO.mmioStoreEvent addr2 v2).
  Proof.
    intros; subst.
    cbv [MinimalMMIO.mmioStoreEvent].
    cbv [MinimalMMIO.signedByteTupleToReg].
    change (8 * Z.of_nat 4) with 32; rewrite H0.
    cbv [word.of_Z word WordsKami wordW KamiWord.word kofZ].
    rewrite ZToWord_wordToZ.
    econstructor.
  Qed.

  Inductive traces_related: list Event -> list LogItem -> Prop :=
  | relate_nil:
      traces_related nil nil
  | relate_cons: forall e e' t t',
      events_related e e' ->
      traces_related t t' ->
      traces_related (e :: t) (e' :: t').

  Definition pc_related_and_valid (kpc rpc: kword width) :=
    AddrAligned rpc /\ pc_related kpc rpc.

  Inductive states_related: KamiMachine * list Event -> RiscvMachine -> Prop :=
  | relate_states:
      forall t t' m riscvXAddrs kpc krf rrf rpc nrpc pinit instrMem kdataMem rdataMem metrics,
        traces_related t t' ->
        KamiProc.RegsToT m = Some (kamiStMk kpc krf pinit instrMem kdataMem) ->
        (pinit = false -> riscvXAddrs = kamiXAddrs) ->
        (pinit = true -> RiscvXAddrsSafe instrMem kdataMem riscvXAddrs) ->
        pc_related_and_valid kpc rpc ->
        nrpc = word.add rpc (word.of_Z 4) ->
        regs_related krf rrf ->
        mem_related _ kdataMem rdataMem ->
        states_related
          (m, t) {| getMachine := {| RiscvMachine.getRegs := rrf;
                                     RiscvMachine.getPc := rpc;
                                     RiscvMachine.getNextPc := nrpc;
                                     RiscvMachine.getMem := rdataMem;
                                     RiscvMachine.getXAddrs := riscvXAddrs;
                                     RiscvMachine.getLog := t'; |};
                    getMetrics := metrics; |}.

  (** * Utility lemmas *)

  Lemma events_related_unique: forall e' e1 e2,
      events_related e1 e' ->
      events_related e2 e' ->
      e1 = e2.
  Proof.
    intros. inversion H; inversion H0; subst; congruence.
  Qed.

  Lemma traces_related_unique: forall {t' t1 t2},
      traces_related t1 t' ->
      traces_related t2 t' ->
      t1 = t2.
  Proof.
    induction t'; intros.
    - inversion H. inversion H0. reflexivity.
    - inversion H. inversion H0. subst. f_equal.
      + eapply events_related_unique; eassumption.
      + eapply IHt'; eassumption.
  Qed.

  Inductive KamiLabelR: Kami.Semantics.LabelT -> list Event -> Prop :=
  | KamiSilent:
      forall klbl,
        klbl.(calls) = FMap.M.empty _ ->
        KamiLabelR klbl nil
  | KamiMMIO:
      forall klbl argV retV e,
        klbl.(calls) =
        FMap.M.add
          "mmioExec"%string
          (existT SignT {| arg := Struct (RqFromProc (Z.to_nat width) rv32DataBytes);
                           ret := Struct (RsToProc rv32DataBytes) |} (argV, retV))
          (FMap.M.empty _) ->
        e = (if argV (Fin.FS Fin.F1)
             then MMOutputEvent (argV Fin.F1) (argV (Fin.FS (Fin.FS (Fin.FS Fin.F1))))
             else MMInputEvent (argV Fin.F1) (retV Fin.F1)) ->
        KamiLabelR klbl [e].

  Definition kamiStep (m1 m2: KamiMachine) (klbl: Kami.Semantics.LabelT): Prop :=
    exists kupd, Step kamiProc m1 kupd klbl /\ m2 = FMap.M.union kupd m1.

  Lemma wlt_kunsigned:
    forall (w1 w2: word),
      (w1 < w2)%word <-> kunsigned w1 < kunsigned w2.
  Proof.
    cbv [kunsigned]; intros.
    apply N2Z.inj_lt.
  Qed.

  Lemma wle_kunsigned:
    forall (w1 w2: word),
      (w1 <= w2)%word <-> kunsigned w1 <= kunsigned w2.
  Proof.
    cbv [kunsigned]; intros; split; intros.
    - apply N2Z.inj_le.
      cbv [wlt] in H; Lia.lia.
    - intro Hx.
      apply N2Z.inj_le in H.
      cbv [wlt] in Hx; Lia.lia.
  Qed.

  Lemma is_mmio_consistent:
    forall a, (isMMIOAddr a /\ isMMIOAligned 4 a) <-> evalExpr (isMMIO type a) = true.
  Proof.
    intros.
    cbv [isMMIOAddr isMMIOAligned FE310_mmio isMMIO kami_FE310_AbsMMIO].
    cbn [evalExpr evalBinBool evalBinBitBool evalUniBool evalUniBit evalConstT].
    cbv [isOTP isPRCI isGPIO0 isUART0 isSPI1].
    rewrite Bool.andb_true_iff.
    rewrite ?Bool.orb_true_iff.
    split; intros.

    - destruct H as [? [_ ?]]; split.
      + destruct (isEq _ _); [reflexivity|elim n; clear n].
        cbv [word.unsigned kunsigned word WordsKami wordW KamiWord.word kofZ] in H0.
        change 4 with (Z.of_N 4%N) in H0.
        rewrite <-N2Z.inj_mod in H0 by discriminate.
        rewrite <-N2Z.inj_0 in H0.
        apply N2Z.inj in H0.
        apply wordToN_inj.
        rewrite wordToN_split1.
        setoid_rewrite H0; reflexivity.

      + repeat match goal with
               | H: _ /\ _ |- _ => destruct H
               | H: _ \/ _ |- _ => destruct H
               end.
        1: do 4 left.
        2: do 3 left; right.
        3: do 2 left; right.
        4: left; right.
        5: right.

        all: cbv [Kx] in *.
        all: repeat
               match goal with
               | |- (_ && _ = true)%bool => apply Bool.andb_true_iff; split
               | |- negb _ = true => apply Bool.negb_true_iff
               | |- (if wlt_dec _ _ then true else false) = true =>
                 destruct (wlt_dec _ _); [reflexivity|exfalso]
               | |- (if wlt_dec _ _ then true else false) = false =>
                 destruct (wlt_dec _ _); [exfalso|reflexivity]
               | H: (_ < _)%word |- _ => apply wlt_kunsigned in H
               | H: (_ <= _)%word |- _ => elim H; clear H
               | |- (_ < _)%word => apply wlt_kunsigned
               | H: context [HexNotation.Ox _] |- _ => cbv [HexNotation.Ox] in H; simpl in H
               | |- context [HexNotation.Ox _] => cbv [HexNotation.Ox]; simpl
               | H: context [kunsigned] |- _ =>
                 cbv [kunsigned word WordsKami wordW KamiWord.word kofZ] in H; simpl in H
               | |- context [kunsigned] =>
                 cbv [kunsigned word WordsKami wordW KamiWord.word kofZ]; simpl
               end.
        all: try Lia.lia.

    - destruct H; repeat split.
      + clear H.
        repeat match goal with
               | H: _ /\ _ |- _ => destruct H
               | H: _ \/ _ |- _ => destruct H
               end.
        1: left.
        2: right; left.
        3: do 2 right; left.
        4: do 3 right; left.
        5: do 4 right.
        all: repeat match goal with | |- _ /\ _ => split end.

        all: cbv [Kx] in *.
        all: repeat
               match goal with
               | H: (_ && _ = true)%bool |- _ => apply Bool.andb_true_iff in H; destruct H
               | H: negb _ = true |- _ => apply Bool.negb_true_iff in H
               | H: (if wlt_dec _ _ then true else false) = true |- _ =>
                 destruct (wlt_dec _ _); [|discriminate]
               | H: (if wlt_dec _ _ then true else false) = false |- _ =>
                 destruct (wlt_dec _ _); [discriminate|]
               | H: (_ < _)%word |- _ => apply wlt_kunsigned in H
               | H: (_ <= _)%word |- _ => apply wle_kunsigned in H
               | |- (_ < _)%word => apply wlt_kunsigned
               | H: context [HexNotation.Ox _] |- _ => cbv [HexNotation.Ox] in H; simpl in H
               | |- context [HexNotation.Ox _] => cbv [HexNotation.Ox]; simpl
               | H: context [kunsigned] |- _ =>
                 cbv [kunsigned word WordsKami wordW KamiWord.word kofZ] in H; simpl in H
               | |- context [kunsigned] =>
                 cbv [kunsigned word WordsKami wordW KamiWord.word kofZ]; simpl
               end.
        all: try Lia.lia.

      + clear -H.
        destruct (isEq _ _); [clear H|discriminate].
        cbv [word.unsigned kunsigned word WordsKami wordW KamiWord.word kofZ].
        change 4 with (Z.of_N 4%N).
        rewrite <-N2Z.inj_mod by discriminate.
        rewrite <-N2Z.inj_0.
        apply f_equal with (f:= @wordToN _) in e.
        rewrite wordToN_split1 in e.
        setoid_rewrite e; reflexivity.
  Qed.

  Lemma mmio_mem_disjoint:
    forall addr, isMMIOAddr addr -> kunsigned addr < 2 ^ memSizeLg -> False.
  Proof.
    intros.
    cbv [isMMIOAddr isMMIOAligned FE310_mmio isMMIO kami_FE310_AbsMMIO] in H.
    cbv [isOTP isPRCI isGPIO0 isUART0 isSPI1] in H.
    cbv [HexNotation.Ox] in H; simpl in H.
    assert (kunsigned addr < 2 ^ 16).
    { eapply Z.lt_le_trans; [eassumption|].
      apply Z.pow_le_mono_r; [Lia.lia|assumption].
    }
    clear H0.
    destruct H as [|[|[|[|]]]]; destruct H; Lia.lia.
  Qed.

  Lemma pgm_init_not_mmio:
    Kami.Ex.SCMMInv.PgmInitNotMMIO rv32Fetch kami_FE310_AbsMMIO.
  Proof.
    red; intros.
    destruct (evalExpr (isMMIO _ _)) eqn:Hmmio; [exfalso|reflexivity].
    apply is_mmio_consistent in Hmmio; destruct Hmmio as [Hmmio _].
    eapply mmio_mem_disjoint; [eassumption|].

    cbv [toAddr rv32Fetch rv32ToAddr eq_rect_r].
    rewrite evalExpr_bit_eq_rect.
    cbv [kunsigned].
    rewrite wordToN_eq_rect.

    cbv [evalExpr evalBinBit evalConstT].
    rewrite ?wordToN_combine, ?wordToN_0.
    rewrite N.mul_0_r, N.add_0_l, N.add_0_r.
    
    transitivity (2 ^ (2 + instrMemSizeLg)).
    - replace (2 + instrMemSizeLg) with (Z.of_nat (2 + Z.to_nat instrMemSizeLg)).
      + rewrite <-NatLib.Z_of_N_Npow2.
        apply N2Z.inj_lt.
        change (NatLib.Npow2 2) with 4%N.
        replace (NatLib.Npow2 (2 + Z.to_nat instrMemSizeLg))
          with (4 * NatLib.Npow2 (Z.to_nat instrMemSizeLg))%N
          by (simpl; destruct (NatLib.Npow2 _); reflexivity).
        apply N.mul_lt_mono_pos_l; [Lia.lia|].
        apply wordToN_bound.
      + rewrite Nat2Z.inj_add.
        rewrite Z2Nat.id by Lia.lia.
        reflexivity.
    - apply Z.pow_lt_mono_r; Lia.lia.
  Qed.

  Lemma kamiStep_sound_case_pgmInit:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "pgmInit"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      states_related (FMap.M.union kupd km1, t0) rm1 /\
      cs = FMap.M.empty _.
  Proof.
    intros.
    inversion H; subst; clear H.
    eapply invert_Kami_pgmInit in H1; eauto;
      [|apply pgm_init_not_mmio].
    unfold kamiStMk in H1; simpl in H1.
    destruct H1 as (? & ? & km2 & ? & ? & ? & ? & ?); subst.
    clear H7.
    destruct km2 as [pc2 rf2 pinit2 pgm2 mem2]; simpl in *; subst.
    split; [|reflexivity].
    econstructor; eauto.
    intros; discriminate.
  Qed.

  Lemma kamiPgmInitFull_RiscvXAddrsSafe:
    forall pgmFull dataMem,
      KamiPgmInitFull rv32Fetch pgmFull dataMem ->
      RiscvXAddrsSafe pgmFull dataMem kamiXAddrs.
  Proof.
    unfold KamiPgmInitFull; intros.
    red; intros.
    split; [assumption|].
    intros.
    red in H2; subst kpc.
    rewrite H.
    cbv [alignInst rv32Fetch rv32AlignInst toAddr]; unfold evalExpr; fold evalExpr.
    f_equal.
    apply kamiXAddrs_isXAddr4_bound in H0.
    apply rv32ToAddr_rv32ToIAddr_consistent; assumption.
  Qed.

  Lemma kamiStep_sound_case_pgmInitEnd:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "pgmInitEnd"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      states_related (FMap.M.union kupd km1, t0) rm1 /\
      cs = FMap.M.empty _.
  Proof.
    intros.
    inversion H; subst; clear H.
    eapply invert_Kami_pgmInitEnd in H1; eauto;
      [|apply pgm_init_not_mmio].
    unfold kamiStMk in H1; simpl in H1.
    destruct H1 as (? & ? & pgmFull & ? & ?); subst.
    clear H7.
    specialize (H6 eq_refl); subst.
    split; [|reflexivity].
    econstructor; eauto.
    intros _.
    apply kamiPgmInitFull_RiscvXAddrsSafe; auto.
  Qed.

  Lemma pc_related_plus4:
    forall kpc rpc,
      pc_related_and_valid kpc rpc ->
      pc_related_and_valid (kpc ^+ $4) (word.add rpc (word.of_Z 4)).
  Proof.
    cbv [pc_related_and_valid]; intros.
    destruct H; split.
    - apply AddrAligned_plus4; assumption.
    - red in H0; subst kpc.
      reflexivity.
  Qed.

  Lemma nat_power_of_two_boundary_shrink:
    forall n z,
      - BinInt.Z.of_nat (Nat.pow 2 n) <= z < BinInt.Z.of_nat (Nat.pow 2 n) ->
      forall m,
        (n < m)%nat ->
        - BinInt.Z.of_nat (Nat.pow 2 m) <= z < BinInt.Z.of_nat (Nat.pow 2 m).
  Proof.
    intros.
    destruct H; split.
    - etransitivity; [|eassumption].
      rewrite <-Z.opp_le_mono.
      apply inj_le.
      apply Nat.pow_le_mono_r; blia.
    - etransitivity; [eassumption|].
      apply inj_lt.
      apply Nat.pow_lt_mono_r; blia.
  Qed.

  Lemma AddrAligned_consistent:
    forall a,
      negb (reg_eqb (MachineWidth:= MachineWidth_XLEN)
                    (remu a (ZToReg 4)) (ZToReg 0)) = false ->
      AddrAligned a.
  Proof.
    intros.
    apply Bool.negb_false_iff in H.
    cbv [reg_eqb MachineWidth_XLEN word.eqb word WordsKami wordW KamiWord.word] in H.
    apply weqb_sound in H.
    cbv [remu word.modu riscvZmodu kofZ kunsigned] in H.
    simpl in H; cbn in H.
    change (Pos.to_nat 32) with 32%nat in H.
    match type of H with
    | _ = ?rhs =>
      change rhs with (wzero 32) in H;
        rewrite <-ZToWord_zero in H
    end.
    apply f_equal with (f:= @wordToZ _) in H.

    rewrite wordToZ_ZToWord in H.
    2: {
      apply nat_power_of_two_boundary_shrink with (n:= 3%nat); [simpl|blia].
      match goal with
      | |- _ <= ?z mod 4 < _ =>
        pose proof (Z.mod_bound_or z 4 ltac:(discriminate)); blia
      end.
    }
    rewrite wordToZ_ZToWord in H
      by (apply nat_power_of_two_boundary_shrink with (n:= 3%nat); simpl; blia).

    cbv [AddrAligned].
    apply wordToN_inj.
    apply N2Z.inj_iff.
    rewrite unsigned_split1_as_bitSlice.
    match goal with
    | |- context [@wordToN ?sz _] => change sz with 32%nat
    end.
    rewrite bitSlice_alt by blia.
    cbv [bitSlice']; cbn.
    rewrite Z.div_1_r.
    assumption.
  Qed.

  Lemma kami_evalZeroExtendTrunc_32:
    forall w, evalZeroExtendTrunc 32 w = w.
  Proof.
    intros; cbv [evalZeroExtendTrunc].
    destruct (lt_dec _ _); [Lia.lia|].
    apply split1_0.
  Qed.
    
  Lemma kami_evalSignExtendTrunc_32:
    forall w, evalSignExtendTrunc 32 w = w.
  Proof.
    intros; cbv [evalSignExtendTrunc].
    destruct (lt_dec _ _); [Lia.lia|].
    apply split1_0.
  Qed.

  Lemma kami_evalZeroExtendTrunc:
    forall {a} (w: Word.word a) b,
      (a < b)%nat ->
      evalZeroExtendTrunc b w = ZToWord b (Z.of_N (wordToN w)).
  Proof.
    case TODO_word.
  Qed.

  Lemma kami_evalSignExtendTrunc:
    forall {a} (w: Word.word a) b,
      (a <= b)%nat ->
      evalSignExtendTrunc b w =
      ZToWord b (signExtend (Z.of_nat a) (Z.of_N (wordToN w))).
  Proof.
    case TODO_word.
  Qed.

  Lemma mem_related_load_bytes_Some:
    forall kmem rmem,
      mem_related memSizeLg kmem rmem ->
      forall sz addr bs,
        sz <> O ->
        Memory.load_bytes sz rmem addr = Some bs ->
        kunsigned addr < Z.pow 2 memSizeLg.
  Proof.
    intros.
    destruct sz as [|sz]; [exfalso; auto|].
    cbn in H1.
    match goal with
    | [H: match ?val with | Some _ => _ | None => _ end = Some _ |- _] =>
      destruct val as [b|] eqn:Hb; [clear H|discriminate]
    end.
    specialize (H addr).
    setoid_rewrite Hb in H.
    destruct (Z.ltb_spec (kunsigned addr) (Z.pow 2 memSizeLg)); [|discriminate].
    assumption.
  Qed.

  Lemma evalZeroExtendTrunc_bound_eq:
    forall (a b: kword width),
      kunsigned a < 2 ^ memSizeLg ->
      kunsigned b < 2 ^ memSizeLg ->
      evalZeroExtendTrunc (BinInt.Z.to_nat memSizeLg) a =
      evalZeroExtendTrunc (BinInt.Z.to_nat memSizeLg) b ->
      a = b.
  Proof.
    cbv [evalZeroExtendTrunc]; intros.
    destruct (lt_dec _ _);
      [apply Z2Nat.inj_le in Hkmem2; [|Lia.lia..]; Lia.lia|].

    apply f_equal with (f:= @wordToN _) in H1.
    rewrite ?wordToN_split1 in H1.
    cbv [eq_rec_r eq_rec] in H1.
    rewrite ?wordToN_eq_rect in H1.
    apply f_equal with (f:= Z.of_N) in H1.
    rewrite ?N2Z.inj_mod in H1 by apply NatLib.Npow2_not_zero.
    rewrite ?NatLib.Z_of_N_Npow2 in H1.
    rewrite ?Z2Nat.id in H1 by Lia.lia.
    rewrite ?Z.mod_small in H1 by (split; [apply N2Z.is_nonneg|assumption]).
    apply N2Z.inj in H1.
    apply wordToN_inj in H1.
    assumption.
  Qed.

  Lemma mem_related_put:
    forall kmem rmem,
      mem_related memSizeLg kmem rmem ->
      forall (na: word) kval rval,
        kunsigned na < 2 ^ memSizeLg ->
        rval = byte.of_Z (word.unsigned kval) ->
        mem_related memSizeLg
                    (fun w => if weq w (evalZeroExtendTrunc _ na) then kval
                              else kmem w)
                    (map.put rmem na rval).
  Proof.
    cbv [mem_related] in *; intros.
    destruct (weq addr na); [subst|].
    - rewrite map.get_put_same.
      destruct_one_match; [|Lia.lia].
      rewrite (rewrite_weq eq_refl).
      reflexivity.
    - rewrite map.get_put_diff by assumption.
      rewrite H.
      destruct_one_match; [|reflexivity].
      destruct_one_match; [|reflexivity].
      elim n; clear n.
      apply evalZeroExtendTrunc_bound_eq; assumption.
  Qed.

  Lemma combineBytes_word_removeXAddr:
    forall xaddrs a ra,
      kunsigned a < 2 ^ memSizeLg ->
      kunsigned (a ^+ (word.of_Z 1)) < 2 ^ memSizeLg ->
      kunsigned (a ^+ (word.of_Z 2)) < 2 ^ memSizeLg ->
      kunsigned (a ^+ (word.of_Z 3)) < 2 ^ memSizeLg ->
      kunsigned ra < 2 ^ memSizeLg ->
      isXAddr4 a (removeXAddr ra xaddrs) ->
      forall kmemd rv,
        combineBytes
          4 a (fun w => if weq w (evalZeroExtendTrunc (BinInt.Z.to_nat memSizeLg) ra)
                        then rv else kmemd w) =
        combineBytes 4 a kmemd.
  Proof.
    intros; cbn.
    destruct H4 as [? [? [? ?]]].
    destruct_one_match.
    1: { exfalso.
         apply evalZeroExtendTrunc_bound_eq in e; [subst|assumption..].
         apply filter_In in H4; destruct H4 as [_ ?].
         apply Bool.negb_true_iff, word.eqb_false in H4; auto.
    }
    destruct_one_match.
    1: { exfalso.
         apply evalZeroExtendTrunc_bound_eq in e; [subst|assumption..].
         apply filter_In in H5; destruct H5 as [_ ?].
         apply Bool.negb_true_iff, word.eqb_false in H5; auto.
    }
    destruct_one_match.
    1: { exfalso.
         rewrite <-?wplus_assoc in e.
         apply evalZeroExtendTrunc_bound_eq in e; [subst|assumption..].
         apply filter_In in H6; destruct H6 as [_ ?].
         apply Bool.negb_true_iff, word.eqb_false in H6; auto.
    }
    destruct_one_match.
    1: { exfalso.
         rewrite <-?wplus_assoc in e.
         apply evalZeroExtendTrunc_bound_eq in e; [subst|assumption..].
         apply filter_In in H7; destruct H7 as [_ ?].
         apply Bool.negb_true_iff, word.eqb_false in H7; auto.
    }
    reflexivity.
  Qed.

  Lemma RiscvXAddrsSafe_removeXAddr_write_ok:
    forall kmemi kmemd xaddrs,
      RiscvXAddrsSafe kmemi kmemd xaddrs ->
      forall ra rv,
        kunsigned ra < 2 ^ memSizeLg ->
        RiscvXAddrsSafe
          kmemi (fun w => if weq w (evalZeroExtendTrunc _ ra) then rv else kmemd w)
          (removeXAddr ra xaddrs).
  Proof.
    cbv [RiscvXAddrsSafe]; intros.
    assert (isXAddr4 rpc xaddrs).
    { destruct H1 as [? [? [? ?]]].
      cbv [isXAddr1 removeXAddr] in *.
      repeat match goal with
             | [H: In _ (filter _ _) |- _] => apply filter_In in H; destruct H
             end.
      red; auto.
    }
    specialize (H _ H2); clear H2; destruct H as [? ?].
    split; [assumption|].

    assert (BinInt.Z.of_N (NatLib.Npow2 (2 + Z.to_nat instrMemSizeLg)) < 2 ^ memSizeLg).
    { rewrite NatLib.Z_of_N_Npow2.
      apply Z.pow_lt_mono_r; Lia.lia.
    }

    intros.
    specialize (H2 H4 _ H5).
    rewrite <-H2.
    destruct H as [? [? [? ?]]].
    repeat match goal with
           | H: isXAddr1 _ _ |- _ =>
             apply kamiXAddrs_isXAddr1_bound in H; apply N2Z.inj_lt in H
           end.
    apply combineBytes_word_removeXAddr with (xaddrs:= xaddrs); try assumption.
    all: etransitivity; eassumption.
  Qed.

  Lemma RiscvXAddrsSafe_removeXAddr_sound:
    forall kmemi kmemd xaddrs,
      RiscvXAddrsSafe kmemi kmemd xaddrs ->
      forall ra, RiscvXAddrsSafe kmemi kmemd (removeXAddr ra xaddrs).
  Proof.
    cbv [RiscvXAddrsSafe]; intros.
    apply H.
    destruct H0 as [? [? [? ?]]].
    cbv [isXAddr1 removeXAddr] in *.
    repeat match goal with
           | [H: In _ (filter _ _) |- _] => apply filter_In in H; destruct H
           end.
    red; auto.
  Qed.

  Lemma kunsigned_combine_shiftl_lor:
    forall {sa} (a: Word.word sa) {sb} (b: Word.word sb),
      Z.of_N (wordToN (Word.combine a b)) =
      Z.lor (Z.shiftl (Z.of_N (wordToN b)) (Z.of_nat sa)) (Z.of_N (wordToN a)).
  Proof.
    case TODO_word.
  Qed.

  Lemma kunsigned_split2_shiftr:
    forall {sz1 sz2} (w: Word.word (sz1 + sz2)),
      Z.of_N (wordToN (split2 _ _ w)) = Z.shiftr (Z.of_N (wordToN w)) (Z.of_nat sz1).
  Proof.
    case TODO_word.
  Qed.

  Lemma kunsigned_byte_split1:
    forall {sz} (w: Word.word (8 + sz)),
      byte.of_Z (Z.of_N (wordToN w)) =
      byte.of_Z (Z.of_N (wordToN (split1 _ _ w))).
  Proof.
    case TODO_word.
  Qed.

  Lemma byte_wrap_word_8:
    forall w: Word.word 8,
      byte.wrap (Z.of_N (wordToN w)) = Z.of_N (wordToN w).
  Proof.
    case TODO_word.
  Qed.

  Lemma split1_combine_16:
    forall (w0 w1 w2 w3: Word.word 8),
      split1 16 16 (Word.combine w0 (Word.combine w1 (Word.combine w2 w3))) =
      Word.combine w0 w1.
  Proof.
    case TODO_word.
  Qed.

  Instance kword32: coqutil.Word.Interface.word 32 := KamiWord.word 32.
  Instance kword32_ok: word.ok kword32. eapply KamiWord.ok. reflexivity. Qed.

  Lemma signExtend_word_of_Z_nop:
    forall z, word.of_Z (width:= 32) (signExtend 32 z) = word.of_Z (width:= 32) z.
  Proof.
    intros.
    apply word.of_Z_inj_mod.
    unfold signExtend.
    (* TODO remove once we're on Coq 8.12 *)
    repeat match goal with
           | |- context[2 ^ ?x] => let r := eval cbv in (2 ^ x) in change (2 ^ x) with r
           end.
    Z.div_mod_to_equations.
    Lia.lia.
  Qed.

  Lemma signExtend_combine_split_signed:
    forall (w: Word.word 32),
      signExtend 32 (combine 4 (split 4 (wordToZ w))) = wordToZ w.
  Proof.
    intros.
    rewrite combine_split.
    change (wordToZ w) with (word.signed w).
    etransitivity. 2: eapply word.swrap_signed.
    unfold word.swrap, signExtend.
    (* TODO remove once we're on Coq 8.12 *)
    repeat match goal with
           | |- context[2 ^ ?x] => let r := eval cbv in (2 ^ x) in change (2 ^ x) with r
           end.
    Z.div_mod_to_equations.
    Lia.lia.
  Qed.

  Lemma signExtend_combine_split_unsigned:
    forall (w: Word.word 32),
      signExtend 32 (combine 4 (split 4 (Z.of_N (wordToN w)))) = wordToZ w.
  Proof.
    intros.
    rewrite combine_split.
    change (wordToZ w) with (word.signed w).
    change (Z.of_N (wordToN w)) with (word.unsigned w).
    rewrite word.signed_eq_swrap_unsigned.
    unfold word.swrap, signExtend.
    (* TODO remove once we're on Coq 8.12 *)
    repeat match goal with
           | |- context[2 ^ ?x] => let r := eval cbv in (2 ^ x) in change (2 ^ x) with r
           end.
    Z.div_mod_to_equations.
    Lia.lia.
  Qed.

  (** * Utility Ltacs *)
  
  Ltac kami_step_case_empty :=
    left; FMap.mred; fail.

  Inductive PHide: Prop -> Prop :=
  | PHidden: forall P: Prop, P -> PHide P.

  Ltac mcomp_step_in HR :=
    progress
      (let ucode := match type of HR with mcomp_sat ?u ?s ?p => u end in
       let state := match type of HR with mcomp_sat ?u ?s ?p => s end in
       let post := match type of HR with mcomp_sat ?u ?s ?p => p end in
       (let uc := fresh "uc" in set ucode as uc in HR; hnf in uc; subst uc);
       let ucode := match type of HR with mcomp_sat ?u ?s ?p => u end in
       change (mcomp_sat ucode state post) in HR;
       match ucode with
       | free.act ?a ?k =>
         let pf := constr:(HR : free.interp interp_action ucode state post) in
         (let HRR := fresh in pose proof pf as HRR; clear HR; rename HRR into HR);
         remember k as kV;
         (* Note:
            conversion is slow if we don't remember k.
            this might be because interp_fix needs to be unfolded once,
            but unfolding it as many times as possible would create a huge term
          *)
         let interp_action := eval cbv delta [interp_action MinimalMMIO.interp_action] in
         interp_action in
         let TR := eval cbn iota beta delta [
                     fst snd
                     getMetrics getMachine
                     translate
                     getRegs getPc getNextPc getMem getXAddrs getLog]
         in (interp_action a state (fun x state' => mcomp_sat (kV x) state' post)) in
             change TR in HR; subst kV
       | free.ret ?v => change (post v state) in HR
       | _ => idtac
       end).

  Ltac destruct_if_by_contradiction :=
    let c := match goal with
             | H : context [if ?c then _ else _] |- _ => c
             | H := context [if ?c then _ else _] |- _ => c
             | |- if ?c then _ else _ => c
             end in
    destruct c; try (exfalso; contradiction); [].

  Ltac zcstP x :=
    let x := rdelta x in
    let t := isZcst x in
    constr_eq t true.
  Ltac natcstP x :=
    let x := rdelta x in
    let t := isnatcst x in
    constr_eq t true.
  Ltac boolcstP x :=
    let x := rdelta x in
    first [constr_eq x true | constr_eq x false].

  Ltac eval2 op arg1P arg2P :=
    repeat match goal with
           | H : context G [op ?x ?y] |- _ =>
             arg1P x; arg2P y;
             let z := eval cbv in (op x y) in
             let e := context G [z] in
             change e in H
           | H := context G [op ?x ?y] |- _ =>
             arg1P x; arg2P y;
             let z := eval cbv in (op x y) in
             let e := context G [z] in
             change e in (value of H)
           | |- context G [op ?x ?y] =>
             arg1P x; arg2P y;
             let z := eval cbv in (op x y) in
             let e := context G [z] in
             change e
           end.

  (* kitchen sink goal simplification? *)
  Ltac t  :=
    match goal with
    | H : ?LHS = let x := ?v in ?C |- _ =>
        change (let x := v in LHS = C) in H
    | H := let x := ?v in @?C x |- _ =>
        let x := fresh x in pose v as x;
        let C := eval cbv beta in (C x) in
        change C in (value of H)
    | H: let x := ?v in @?C x |- _ =>
        let x := fresh x in pose v as x;
        let C := eval cbv beta in (C x) in
        change C in H
    | |- let x := _ in _ => intro
    | x := ?y |- _ => first [is_var y|is_const y|is_ind y|is_constructor y]; subst x
    | H : context G [ Z.of_nat ?n ] |- _ =>
        natcstP n;
        let nn := eval cbv in (Z.of_nat n) in
        let e := context G [nn] in
        change e in H
    | _ => progress eval2 Z.add zcstP zcstP
    | _ => progress eval2 Z.eqb zcstP zcstP
    | H: ?t = ?t -> _ |- _ => specialize (H eq_refl)
    | H: mcomp_sat _ _ _ |- _ => mcomp_step_in H
    | H: exists _, _ |- _ => destruct H
    | H: _ /\ _ |- _ => destruct H
    | _ => destruct_if_by_contradiction
    end.

  (* simplification for riscv-coq semantics (execution) *)
  Ltac r :=
    match goal with
    | [H: context G [let x := ?y in @?z x] |- _] =>
      let x' := fresh x in
      pose y as x';
      let zy := eval cbv beta in (z x') in
      let h' := context G [zy] in
      change h' in H
    | [H: Memory.load_bytes _ _ _ = Some _, G: context [Memory.load_bytes] |- _] =>
      rewrite H in G
    | _ => (* the below tactic should precede evaluation for [mcomp_sat] *)
      progress cbn iota beta delta [when free.bind] in *
    | [H: mcomp_sat _ _ _ |- _] =>
      match type of H with
      | context G [when ?b _] => destr b
      | context G [if ?b then _ else _] => destr b
      end
    | [H: combine ?n ?rinst = _, G: context [combine ?n ?rinst] |- _] =>
      setoid_rewrite H in G
    | [H: False |- _] => case H
    | [H: _ |- _] =>
      progress
        (cbv beta delta [load store] in H;
         cbn beta iota delta [
           load store fst snd translate
           withMetrics updateMetrics getMachine getMetrics getRegs getPc getNextPc getMem getXAddrs getLog withRegs withPc withNextPc withMem withXAddrs withLog withLogItem withLogItems
           RiscvMachine.withRegs RiscvMachine.withPc RiscvMachine.withNextPc RiscvMachine.withMem RiscvMachine.withXAddrs RiscvMachine.withLog RiscvMachine.withLogItem RiscvMachine.withLogItems] in H)
    end.

  Ltac rt := repeat (r || t).
  
  Ltac prove_KamiLabelR_silent :=
    split; [|split];
    [eapply KamiSilent; reflexivity| |eassumption].
  Ltac prove_KamiLabelR_mmio :=
    split; [|split];
    [eapply KamiMMIO; reflexivity| |eassumption].

  Ltac regs_get_red_goal :=
    repeat
      (try (erewrite <-regs_related_get
              with (w:= split2 15 5 (split1 (15 + 5) 12 _));
            [|eauto; fail|eassumption|eapply unsigned_split2_split1_as_bitSlice; fail]);
       try (erewrite <-regs_related_get
              with (w:= split2 20 5 (split1 (20 + 5) 7 _));
            [|eauto; fail|eassumption|eapply unsigned_split2_split1_as_bitSlice; fail])).

  Ltac regs_get_red H :=
    repeat
      (try (erewrite <-regs_related_get
              with (w:= split2 15 5 (split1 (15 + 5) 12 _)) in H;
            [|eauto; fail|eassumption|eapply unsigned_split2_split1_as_bitSlice; fail]);
       try (erewrite <-regs_related_get
              with (w:= split2 20 5 (split1 (20 + 5) 7 _)) in H;
            [|eauto; fail|eassumption|eapply unsigned_split2_split1_as_bitSlice; fail])).
  
  Ltac prove_states_related :=
    econstructor;
    [try (solve [trivial])
    |clear; cbv [RegsToT pRegsToT]; kregmap_red; exact eq_refl
    |clear; intro; discriminate
    |try (solve [trivial])
    |cbv [RiscvMachine.getNextPc];
     try (eapply pc_related_plus4; try eassumption; red; eauto; fail)
    |solve [trivial]
    |try (solve [trivial]);
     try (eapply regs_related_put;
          [solve [trivial]|solve [trivial]|..];
          erewrite ?regs_related_get, ?unsigned_split2_split1_as_bitSlice by eauto;
          trivial)
    |try (solve [trivial])].

  Ltac kinvert_pre :=
    repeat
      match goal with
      | [H: PHide (Step _ _ _ _) |- _] => inversion H; subst; clear H
      | [H: SemAction _ _ _ _ _ |- _] => clear H
      | [H: (_ :: _)%struct = (_ :: _)%struct |- _] => inversion H; subst; clear H
      | [H: context [annot ?klbl] |- _] =>
        let annot := fresh "annot" in
        let defs := fresh "defs" in
        let calls := fresh "calls" in
        destruct klbl as [annot defs calls];
        cbn [Semantics.annot Semantics.defs Semantics.calls] in *; subst;
        destruct annot; [|discriminate]
      | [H: Rle _ = Rle _ |- _] => inversion H; subst; clear H
      end.

  Ltac kinvert_more :=
    kinvert;
    try (repeat
           match goal with
           | [H: Semantics.annot ?klbl = Some _ |- _] => rewrite H in *
           | [H: (_ :: _)%struct = (_ :: _)%struct |- _] =>
             inversion H; subst; clear H
           end; discriminate).

  Ltac invertActionRep_nosimpl :=
    repeat
      match goal with
      | H: (_ :: _)%struct = (_ :: _)%struct |- _ => CommonTactics.inv H
      | H: SemAction _ _ _ _ _ |- _ =>
        apply inversionSemAction in H; CommonTactics.dest
      | H: if ?c
           then SemAction _ _ _ _ _ /\ _ /\ _ /\ _
           else SemAction _ _ _ _ _ /\ _ /\ _ /\ _ |- _ =>
        repeat autounfold with MethDefs;
        match goal with
        | H: if ?c
             then SemAction _ _ _ _ _ /\ _ /\ _ /\ _
             else SemAction _ _ _ _ _ /\ _ /\ _ /\ _ |- _ =>
          let ic := fresh "ic" in
          remember c as ic; destruct ic; CommonTactics.dest
        end
      end.

  Ltac kinv_action_dest_nosimpl :=
    kinv_red; invertActionRep_nosimpl.

  Ltac block_subst vn :=
    match goal with
    | [H: vn = ?v |- _] =>
      assert (PHide (vn = v)) by (constructor; assumption); clear H
    end.

  Ltac red_regmap :=
    try match goal with
        | [H: scmm_inv _ _ _ _ |- _] => inversion H
        end;
    cbv [RegsToT pRegsToT] in *;
    kregmap_red; kinv_red.

  Ltac red_trivial_conds :=
    repeat
      match goal with
      | [H: evalExpr (Var type (SyntaxKind Bool) ?b) = _ |- _] => simpl in H; subst b
      end.

  Ltac cleanup_trivial :=
    cbv [Semantics.annot Semantics.defs Semantics.calls] in *;
    repeat
      match goal with
      | [H: FMap.M.empty _ = FMap.M.empty _ |- _] => clear H
      | [H: true = false -> _ |- _] => clear H
      | [H: false = true -> _ |- _] => clear H
      | [H: Some _ = Some _ |- _] => inversion H; subst; clear H
      | [H: {| pc := _ |} = kamiStMk _ _ _ _ _ |- _] => inversion H; subst; clear H
      | [H: true = true -> _ |- _] => specialize (H eq_refl)
      | [H: context [FMap.M.Map.In] |- _] => clear H
      end.

  Ltac unblock_subst vn :=
    match goal with
    | [H: PHide (vn = _) |- _] => inversion_clear H
    end.

  Ltac eval_kami_fetch :=
    try match goal with
        | [H: pc_related_and_valid _ _ |- _] => destruct H
        end;
    try match goal with
        | [H: isXAddr4 _ _ |- _] =>
          let Hxaddr := fresh "Hxaddr" in
          pose proof H as Hxaddr;
          eapply fetch_ok in H; try eassumption; [|Lia.lia];
          let rinst := fresh "rinst" in
          destruct H as (rinst & ? & ?)
        end.
  
  Ltac kami_cbn_all :=
    cbn [evalExpr evalUniBool evalBinBool evalBinBit
                  evalConstT getDefaultConst isEq Data BitsPerByte Nat.mul Nat.add Nat.sub
                  AlignInstT DstE DstK DstT ExecT f3Lb f3Lbu f3Lh f3Lhu f3Lw getFunct3E getFunct6E getFunct7E getOffsetIE getOffsetSBE getOffsetSE getOffsetShamtE getHiShamtE getOffsetUE getOffsetUJE getOpcodeE getRdE getRs1E getRs1ValueE getRs2E getRs2ValueE IsMMIOE IsMMIOT LdAddrCalcT LdAddrE LdAddrK LdAddrT LdDstE LdDstK LdDstT LdSrcE LdSrcK LdSrcT LdTypeE LdTypeK LdTypeT LdValCalcT MemInit memInst memOp mm mmioExec nextPc NextPcT OpcodeE OpcodeK OpcodeT opLd opNm opSt OptypeE OptypeK OptypeT Pc pinst procInitDefault procInst RqFromProc RsToProc rv32AlignInst rv32CalcLdAddr rv32CalcStAddr rv32CalcStByteEn rv32DataBytes rv32GetDst rv32GetLdAddr rv32GetLdDst rv32GetLdSrc rv32GetLdType rv32GetOptype rv32GetSrc1 rv32GetSrc2 rv32GetStAddr rv32GetStSrc rv32GetStVSrc rv32InstBytes rv32RfIdx scmm Src1E Src1K Src1T Src2E Src2K Src2T StAddrCalcT StByteEnCalcT StAddrE StAddrK StAddrT StateE StateK StateT StSrcE StSrcK StSrcT StVSrcE StVSrcK StVSrcT] in *.
  
  Ltac kami_cbn_hint H func :=
    let t := type of H in
    let tc :=
      eval cbn [evalExpr evalUniBool evalBinBool evalBinBit
                evalConstT getDefaultConst isEq Data BitsPerByte Nat.mul Nat.add Nat.sub
                func
                (* grep -oP 'Definition \w+' ~/plv/bedrock2/deps/kami/Kami/Ex/{IsaRv32.v,SC.v} | cut -d' ' -f2 | sort | uniq | tr '\n' ' ' ; printf '\n' *)
                AlignInstT DstE DstK DstT ExecT f3Lb f3Lbu f3Lh f3Lhu f3Lw getFunct3E getFunct6E getFunct7E getOffsetIE getOffsetSBE getOffsetSE getOffsetShamtE getHiShamtE getOffsetUE getOffsetUJE getOpcodeE getRdE getRs1E getRs1ValueE getRs2E getRs2ValueE IsMMIOE IsMMIOT LdAddrCalcT LdAddrE LdAddrK LdAddrT LdDstE LdDstK LdDstT LdSrcE LdSrcK LdSrcT LdTypeE LdTypeK LdTypeT LdValCalcT MemInit memInst memOp mm mmioExec nextPc NextPcT OpcodeE OpcodeK OpcodeT opLd opNm opSt OptypeE OptypeK OptypeT Pc pinst procInitDefault procInst RqFromProc RsToProc rv32AlignInst rv32CalcLdAddr rv32CalcStAddr rv32CalcStByteEn rv32DataBytes rv32GetDst rv32GetLdAddr rv32GetLdDst rv32GetLdSrc rv32GetLdType rv32GetOptype rv32GetSrc1 rv32GetSrc2 rv32GetStAddr rv32GetStSrc rv32GetStVSrc rv32InstBytes rv32RfIdx scmm Src1E Src1K Src1T Src2E Src2K Src2T StAddrCalcT StByteEnCalcT StAddrE StAddrK StAddrT StateE StateK StateT StSrcE StSrcK StSrcT StVSrcE StVSrcK StVSrcT]
    in t in
    let Ht := fresh "H" in
    assert (Ht: t = tc) by reflexivity;
    rewrite Ht in H; clear Ht.

  Ltac weq_to_Zeqb :=
    (* -- convert [weq] to [Z.eqb] in Kami decoding/execution *)
    (** Heads-up: COQBUG(rewrite pattern matching on if/match is broken
     * due to "hidden branch types") *)
    repeat match goal with
           | |- context G [if ?x then ?a else ?b] =>
             let e := context G [@bool_rect (fun _ => _) a b x] in
             change e
           | |- context G [if ?x then ?a else ?b] =>
             let e := context G [@sumbool_rect _ _ (fun _ => _) (fun _ => a) (fun _ => b) x] in
             change e
           | H : context G [if ?x then ?a else ?b] |- _ =>
             let e := context G [@bool_rect (fun _ => _) a b x] in
             change e in H
           | H : context G [if ?x then ?a else ?b] |- _ =>
             let e := context G [@sumbool_rect _ _ (fun _ => _) (fun _ => a) (fun _ => b) x] in
             change e in H
           end;
    repeat match goal with
           | [H: _ |- _] =>
             progress repeat rewrite ?sumbool_rect_bool_weq, <-?unsigned_eqb in H
           end;
    repeat rewrite ?sumbool_rect_bool_weq, <-?unsigned_eqb;
    cbv [bool_rect] in *;
    (* -- some more word-to-Z conversions *)
    progress
      repeat (match goal with
              | [ |- context G [Z.of_N (@wordToN ?n ?x)] ] =>
                let nn := eval cbv in (Z.of_nat n) in
                let e := context G [@kunsigned nn x] in
                change e
              | [ |- context G [kunsigned (@natToWord ?n ?x)] ] =>
                let xx := eval cbv in (Z.of_nat x) in
                let e := context G [xx] in
                change e
              | [ |- context G [kunsigned (@WS ?b ?n ?t)] ] =>
                let xx := eval cbv in (kunsigned (width:= Z.of_nat (S n)) (WS b t)) in
                let e := context G [xx] in
                change e
              | [H: context G [Z.of_N (@wordToN ?n ?x)] |- _] =>
                let nn := eval cbv in (Z.of_nat n) in
                let e := context G [@kunsigned nn x] in
                change e in H
              | [H: context G [kunsigned (@natToWord ?n ?x)] |- _] =>
                let xx := eval cbv in (Z.of_nat x) in
                let e := context G [xx] in
                change e in H
              | [H: context G [kunsigned (@WS ?b ?n ?t)] |- _] =>
                let xx := eval cbv in (kunsigned (width:= Z.of_nat (S n)) (WS b t)) in
                let e := context G [xx] in
                change e in H
              end).

  Ltac dest_Zeqb :=
    progress
      repeat match goal with
             | [ |- context G [if Z.eqb ?x ?y then ?a else ?b] ] =>
               destruct (Z.eqb_spec x y) in *
             | [H : context G [if Z.eqb ?x ?y then ?a else ?b] |- _] =>
               destruct (Z.eqb_spec x y) in *

             | [H : context G [if (Z.eqb ?x ?y && _)%bool then _ else _] |- _] =>
               destruct (Z.eqb_spec x y)
             | [H : context G [if (_ && Z.eqb ?x ?y)%bool then _ else _] |- _] =>
               destruct (Z.eqb_spec x y)

             | [H : context G [if (Z.eqb ?x ?y && _ && _)%bool then _ else _] |- _] =>
               destruct (Z.eqb_spec x y)
             | [H : context G [if (_ && Z.eqb ?x ?y && _)%bool then _ else _] |- _] =>
               destruct (Z.eqb_spec x y)
             | [H : context G [if (_ && _ && Z.eqb ?x ?y)%bool then _ else _] |- _] =>
               destruct (Z.eqb_spec x y)

             | [H: ?x = ?a, G: ?x = ?b |- _] =>
               let aa := eval cbv in a in
               let bb := eval cbv in b in
               let t := isZcst aa in constr_eq t true;
               let t := isZcst bb in constr_eq t true;
               assert_fails (constr_eq aa bb);
               exfalso; remember x; clear -H G;
               cbv in H; cbv in G; rewrite H in G; inversion G
             | [H: ?x = ?a, G: ?x <> ?b |- _] =>
               let aa := eval cbv in a in
               let bb := eval cbv in b in
               let t := isZcst aa in constr_eq t true;
               let t := isZcst bb in constr_eq t true;
               assert_fails (constr_eq aa bb);
               clear G
             end.

  Ltac simpl_bit_manip :=
    cbv [evalUniBit] in *;
    repeat match goal with
           | [H: context [evalZeroExtendTrunc _ _] |- _] =>
             rewrite kami_evalZeroExtendTrunc_32 in H
           | [H: context [evalSignExtendTrunc _ _] |- _] =>
             rewrite kami_evalSignExtendTrunc_32 in H
           end;
    repeat match goal with
           | [H: context [evalSignExtendTrunc _ _] |- _] =>
             rewrite kami_evalSignExtendTrunc in H by (compute; Lia.lia)
           end;
    cbv [kunsigned] in *;
    repeat match goal with
           | [H: context [Z.to_nat ?z] |- _] =>
             let t := isZcst z in
             constr_eq t true;
             let n := eval cbv in (Z.to_nat z) in
                 change (Z.to_nat z) with n in H
           end;
    repeat match goal with
           | [H: context [Z.of_N (wordToN (split2 ?va ?vb (split1 _ _ ?w)))] |- _] =>
             is_var w; rewrite unsigned_split2_split1_as_bitSlice
                         with (a:= va) (b:= vb) (x:= w) in H
           | [H: context [Z.of_N (wordToN (split1 ?va ?vb ?w))] |- _] =>
             is_var w; rewrite unsigned_split1_as_bitSlice
                         with (a:= va) (b:= vb) (x:= w) in H
           | [H: context [Z.of_N (wordToN (split2 ?va ?vb ?w))] |- _] =>
             is_var w; rewrite unsigned_split2_as_bitSlice
                         with (a:= va) (b:= vb) (x:= w) in H
           end;
    repeat match goal with
           | H : context [ Z.of_nat ?n ] |- _ =>
             natcstP n;
             let nn := eval cbv in (Z.of_nat n) in
             change (Z.of_nat n) with nn in H
           end;
    repeat match goal with
           | H : context [ Z.add ?x ?y ] |- _ =>
             let t := isZcst x in constr_eq t true;
             let t := isZcst y in constr_eq t true;
             let z := eval cbv in (Z.add x y) in
             change (Z.add x y) with z in H
           end;
    repeat match goal with
           | H : context [ Z.of_N (@wordToN ?w ?x) ] |- _ =>
             change (Z.of_N (@wordToN w x)) with (@kunsigned 32 x) in H
           end.

  Ltac eval_decode :=
    idtac "KamiRiscv: evaluating [decode] in riscv-coq; this might take several minutes...";
    let dec := fresh "dec" in
    let Hdec := fresh "Hdec" in
    match goal with
    | H : context[decode ?a ?b] |- _ => remember (decode a b) as dec eqn:Hdec in H
    end;
    cbv beta iota delta [decode] in Hdec;
    repeat
      match goal with
      | [Hbs: bitSlice _ _ _ = _ |- _] => rewrite !Hbs in Hdec
      end;
    repeat
      (match goal with
       | _ => progress cbn iota beta delta
                       [iset andb
                             Z.gtb Z.eqb Pos.eqb
                             BinInt.Z.of_nat Pos.of_succ_nat
                             BinInt.Z.compare Pos.compare Pos.compare_cont
                             Datatypes.length nth
                             (* grep Definition ./deps/riscv-coq/src/riscv/Spec/Decode.v | cut -d' ' -f2 | sort | uniq | tr '\n' ' ' ; echo *)
                             bitwidth decode FPRegister funct12_EBREAK funct12_ECALL funct12_MRET funct12_SRET funct12_URET funct12_WFI funct2_FMADD_S funct3_ADD funct3_ADDI funct3_ADDIW funct3_ADDW funct3_AMOD funct3_AMOW funct3_AND funct3_ANDI funct3_BEQ funct3_BGE funct3_BGEU funct3_BLT funct3_BLTU funct3_BNE funct3_CSRRC funct3_CSRRCI funct3_CSRRS funct3_CSRRSI funct3_CSRRW funct3_CSRRWI funct3_DIV funct3_DIVU funct3_DIVUW funct3_DIVW funct3_FCLASS_S funct3_FENCE funct3_FENCE_I funct3_FEQ_S funct3_FLE_S funct3_FLT_S funct3_FLW funct3_FMAX_S funct3_FMIN_S funct3_FMV_X_W funct3_FSGNJN_S funct3_FSGNJ_S funct3_FSGNJX_S funct3_FSW funct3_LB funct3_LBU funct3_LD funct3_LH funct3_LHU funct3_LW funct3_LWU funct3_MUL funct3_MULH funct3_MULHSU funct3_MULHU funct3_MULW funct3_OR funct3_ORI funct3_PRIV funct3_REM funct3_REMU funct3_REMUW funct3_REMW funct3_SB funct3_SD funct3_SH funct3_SLL funct3_SLLI funct3_SLLIW funct3_SLLW funct3_SLT funct3_SLTI funct3_SLTIU funct3_SLTU funct3_SRA funct3_SRAI funct3_SRAIW funct3_SRAW funct3_SRL funct3_SRLI funct3_SRLIW funct3_SRLW funct3_SUB funct3_SUBW funct3_SW funct3_XOR funct3_XORI funct5_AMOADD funct5_AMOAND funct5_AMOMAX funct5_AMOMAXU funct5_AMOMIN funct5_AMOMINU funct5_AMOOR funct5_AMOSWAP funct5_AMOXOR funct5_LR funct5_SC funct6_SLLI funct6_SRAI funct6_SRLI funct7_ADD funct7_ADDW funct7_AND funct7_DIV funct7_DIVU funct7_DIVUW funct7_DIVW funct7_FADD_S funct7_FCLASS_S funct7_FCVT_S_W funct7_FCVT_W_S funct7_FDIV_S funct7_FEQ_S funct7_FMIN_S funct7_FMUL_S funct7_FMV_W_X funct7_FMV_X_W funct7_FSGNJ_S funct7_FSQRT_S funct7_FSUB_S funct7_MUL funct7_MULH funct7_MULHSU funct7_MULHU funct7_MULW funct7_OR funct7_REM funct7_REMU funct7_REMUW funct7_REMW funct7_SFENCE_VMA funct7_SLL funct7_SLLIW funct7_SLLW funct7_SLT funct7_SLTU funct7_SRA funct7_SRAIW funct7_SRAW funct7_SRL funct7_SRLIW funct7_SRLW funct7_SUB funct7_SUBW funct7_XOR isValidA isValidA64 isValidCSR isValidF isValidF64 isValidI isValidI64 isValidM isValidM64 Opcode opcode_AMO opcode_AUIPC opcode_BRANCH opcode_JAL opcode_JALR opcode_LOAD opcode_LOAD_FP opcode_LUI opcode_MADD opcode_MISC_MEM opcode_MSUB opcode_NMADD opcode_NMSUB opcode_OP opcode_OP_32 opcode_OP_FP opcode_OP_IMM opcode_OP_IMM_32 opcode_STORE opcode_STORE_FP opcode_SYSTEM Register RoundMode rs2_FCVT_L_S rs2_FCVT_LU_S rs2_FCVT_W_S rs2_FCVT_WU_S supportsA supportsF supportsM] in *
       | x := @nil _ |- _ => subst x
       | _ => t
       end).

  Ltac eval_decodeI decodeI :=
    try cbn in decodeI;
    cbv [funct12_EBREAK funct12_ECALL funct12_MRET funct12_SRET funct12_URET funct12_WFI funct2_FMADD_S funct3_ADD funct3_ADDI funct3_ADDIW funct3_ADDW funct3_AMOD funct3_AMOW funct3_AND funct3_ANDI funct3_BEQ funct3_BGE funct3_BGEU funct3_BLT funct3_BLTU funct3_BNE funct3_CSRRC funct3_CSRRCI funct3_CSRRS funct3_CSRRSI funct3_CSRRW funct3_CSRRWI funct3_DIV funct3_DIVU funct3_DIVUW funct3_DIVW funct3_FCLASS_S funct3_FENCE funct3_FENCE_I funct3_FEQ_S funct3_FLE_S funct3_FLT_S funct3_FLW funct3_FMAX_S funct3_FMIN_S funct3_FMV_X_W funct3_FSGNJN_S funct3_FSGNJ_S funct3_FSGNJX_S funct3_FSW funct3_LB funct3_LBU funct3_LD funct3_LH funct3_LHU funct3_LW funct3_LWU funct3_MUL funct3_MULH funct3_MULHSU funct3_MULHU funct3_MULW funct3_OR funct3_ORI funct3_PRIV funct3_REM funct3_REMU funct3_REMUW funct3_REMW funct3_SB funct3_SD funct3_SH funct3_SLL funct3_SLLI funct3_SLLIW funct3_SLLW funct3_SLT funct3_SLTI funct3_SLTIU funct3_SLTU funct3_SRA funct3_SRAI funct3_SRAIW funct3_SRAW funct3_SRL funct3_SRLI funct3_SRLIW funct3_SRLW funct3_SUB funct3_SUBW funct3_SW funct3_XOR funct3_XORI funct5_AMOADD funct5_AMOAND funct5_AMOMAX funct5_AMOMAXU funct5_AMOMIN funct5_AMOMINU funct5_AMOOR funct5_AMOSWAP funct5_AMOXOR funct5_LR funct5_SC funct6_SLLI funct6_SRAI funct6_SRLI funct7_ADD funct7_ADDW funct7_AND funct7_DIV funct7_DIVU funct7_DIVUW funct7_DIVW funct7_FADD_S funct7_FCLASS_S funct7_FCVT_S_W funct7_FCVT_W_S funct7_FDIV_S funct7_FEQ_S funct7_FMIN_S funct7_FMUL_S funct7_FMV_W_X funct7_FMV_X_W funct7_FSGNJ_S funct7_FSQRT_S funct7_FSUB_S funct7_MUL funct7_MULH funct7_MULHSU funct7_MULHU funct7_MULW funct7_OR funct7_REM funct7_REMU funct7_REMUW funct7_REMW funct7_SFENCE_VMA funct7_SLL funct7_SLLIW funct7_SLLW funct7_SLT funct7_SLTU funct7_SRA funct7_SRAIW funct7_SRAW funct7_SRL funct7_SRLIW funct7_SRLW funct7_SUB funct7_SUBW funct7_XOR isValidA isValidA64 isValidCSR isValidF isValidF64 isValidI isValidI64 isValidM isValidM64 Opcode opcode_AMO opcode_AUIPC opcode_BRANCH opcode_JAL opcode_JALR opcode_LOAD opcode_LOAD_FP opcode_LUI opcode_MADD opcode_MISC_MEM opcode_MSUB opcode_NMADD opcode_NMSUB opcode_OP opcode_OP_32 opcode_OP_FP opcode_OP_IMM opcode_OP_IMM_32 opcode_STORE opcode_STORE_FP opcode_SYSTEM Register RoundMode rs2_FCVT_L_S rs2_FCVT_LU_S rs2_FCVT_W_S rs2_FCVT_WU_S supportsA supportsF supportsM] in *;
    repeat match goal with
           | [v := context [Z.eqb ?x ?y], H: ?x <> ?y |- _] =>
             destruct (Z.eqb_spec x y) in *; [exfalso; auto; fail|cbn in v]
           end;
    try cbn in decodeI.

  (** * FIXME: this ltac is strongly suspicious of making Qed taking forever .. *)
  Ltac kami_struct_cbv H :=
    cbv [ilist.ilist_to_fun_m
           Notations.icons'
           VectorFacts.Vector_nth_map VectorFacts.Vector_nth_map' Fin.t_rect
           VectorFacts.Vector_find VectorFacts.Vector_find'
           Notations.fieldAccessor
           Struct.attrName StringEq.string_eq StringEq.ascii_eq Bool.eqb andb
           Vector.caseS projT2] in H.
  Ltac kami_struct_cbv_goal :=
    cbv [ilist.ilist_to_fun_m
           Notations.icons'
           VectorFacts.Vector_nth_map VectorFacts.Vector_nth_map' Fin.t_rect
           VectorFacts.Vector_find VectorFacts.Vector_find'
           Notations.fieldAccessor
           Struct.attrName StringEq.string_eq StringEq.ascii_eq Bool.eqb andb
           Vector.caseS projT2].

  (** * Step-consistency lemmas *)
  Arguments isMMIO: simpl never.
  
  Lemma kamiStep_sound_case_execLd:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "execLd"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      exists rm2 t,
        KamiLabelR
          {| annot := Some (Some "execLd"%string);
             defs := FMap.M.empty _;
             calls := cs |} t /\
        states_related (FMap.M.union kupd km1, t ++ t0) rm2 /\ post rm2.
  Proof.
    intros.
    match goal with
    | [H: states_related _ _ |- _] => inversion H; subst; clear H
    end.
    kinvert_more.
    kinv_action_dest_nosimpl.
    3: (* store (contradiction) *) exfalso; clear -Heqic0; discriminate.

    - (** MMIO-load *)
      block_subst kupd.
      red_regmap.
      red_trivial_conds.
      cleanup_trivial.
      unblock_subst kupd.

      (** Evaluate (invert) the two fetchers *)
      rt. eval_kami_fetch. rt.

      (** Begin symbolic evaluation of Kami decode/execute *)
      kami_cbn_all.
      kami_struct_cbv Heqic.
      kami_struct_cbv H.

      (* -- pick the subterm for the Kami instruction *)
      match goal with
      | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
      end.
      repeat
        match goal with
        | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
        | [ |- context [instrMem ?ipc] ] => change (instrMem ipc) with kinst
        end.
      clearbody kinst.

      (* -- pick the load value calculator for simplification *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32CalcLdVal ?sz ?ty ?la ?lv ?lty)] |- _] =>
        remember (@evalExpr fk (rv32CalcLdVal sz ty la lv lty)) as ldVal
      end.
      kami_cbn_hint HeqldVal rv32CalcLdVal.
      
      (* -- pick the nextPc function *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
        remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
      end.
      kami_cbn_hint Heqnpc rv32NextPc.

      weq_to_Zeqb.

      (* -- eliminate trivially contradictory cases *)
      match type of H15 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H15; [discriminate|clear H15]
      end.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; [clear H14|discriminate]
      end.
      match type of e with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in e; [clear e|]
      end.
      2: match type of e with
         | context [Z.eqb ?x ?y] =>
           destruct (Z.eqb_spec x y) in e; discriminate
         end.

      (* -- separate out cases of Kami execution *)
      dest_Zeqb.
      
      (* -- further simplification *)
      all: simpl_bit_manip.

      (** Evaluation of riscv-coq decode/execute *)
      
      all: eval_decode.
      all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
        try subst shamtHi; try subst shamtHiTest.
      all: eval_decodeI decodeI.
      
      (* -- evaluate the execution of riscv-coq *)
      5: match goal with
         | [decodeI := if ?x =? ?y then Lw _ _ _ else InvalidI |- _] =>
           destruct (Z.eqb_spec x y) in *
         end.
      all: subst dec; mcomp_step_in H5;
        repeat match goal with
               | H : False |- _ => case H
               | H : Z |- _ => clear H
               | H : list Instruction |- _ => clear H
               | H : Instruction |- _ => clear H
               end.

      (** Consistency proof for each instruction *)
      all: rt.

      all: unfold evalExpr in Heqic; fold evalExpr in Heqic.
      all: try match goal with
               | [H: match Memory.load_bytes ?sz ?m ?a with | Some _ => _ | None => _ end |- _] =>
                 destruct (Memory.load_bytes sz m a) as [lv|] eqn:Hlv; [exfalso|]
               end.
      all: try (subst v oimm12;
                regs_get_red Hlv;
                match goal with
                | [Heqic: true = evalExpr (isMMIO _ _) |- _] =>
                  apply eq_sym, is_mmio_consistent in Heqic;
                  destruct Heqic as [Heqic _];
                  eapply mem_related_load_bytes_Some in Hlv; [|eassumption|discriminate];
                  clear -Heqic Hlv Hkmemdisj;
                  eapply mmio_mem_disjoint; eassumption
                end).

      all: match goal with
           | [H: nonmem_load _ _ _ _ _ |- _] =>
             let Hpost := fresh "H" in
             destruct H as [? [? Hpost]]; specialize (Hpost (split _ (wordToZ ldVal)))
           end.
      all: try match goal with
               | [H: isMMIOAligned _ _ |- _] =>
                 exfalso; clear -H; destruct H as [? ?]; discriminate
               end.
      
      rt.
      eexists _, _.
      prove_KamiLabelR_mmio.
      try subst regs; try subst kupd.

      prove_states_related.
      { kami_struct_cbv_goal; cbn [evalExpr evalConstT].
        subst v oimm12 ldVal.
        regs_get_red_goal.
        constructor; [|assumption].
        apply events_related_mmioLoadEvent.
        { rewrite kami_evalZeroExtendTrunc_32.
          rewrite kami_evalSignExtendTrunc by (cbv; Lia.lia).
          rewrite unsigned_split2_as_bitSlice.
          reflexivity.
        }
        { apply signExtend_combine_split_signed. }
      }
      { subst ldVal.
        cbv [int32ToReg
               MachineWidth_XLEN word.of_Z word WordsKami wordW KamiWord.word kofZ].
        setoid_rewrite signExtend_combine_split_signed.
        apply eq_sym, ZToWord_wordToZ.
      }

    - (** load *)
      block_subst kupd.
      red_regmap.
      red_trivial_conds.
      cleanup_trivial.
      unblock_subst kupd.

      (** Evaluate (invert) the two fetchers *)
      rt. eval_kami_fetch. rt.

      (** Symbolic evaluation of Kami decode/execute *)
      clear Heqic0.
      kami_cbn_all.
      kami_struct_cbv Heqic.
      kami_struct_cbv H.

      (* -- pick the subterm for the Kami instruction *)
      match goal with
      | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
      end.
      repeat
        match goal with
        | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
        end.
      clearbody kinst.

      (* -- pick the load value calculator for simplification *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32CalcLdVal ?sz ?ty ?la ?lv ?lty)] |- _] =>
        remember (@evalExpr fk (rv32CalcLdVal sz ty la lv lty)) as ldVal
      end.
      kami_cbn_hint HeqldVal rv32CalcLdVal.
      
      (* -- pick the nextPc function *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
        remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
      end.
      kami_cbn_hint Heqnpc rv32NextPc.

      (* -- eliminate trivially contradictory cases *)
      weq_to_Zeqb.
      match type of H15 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H15; [discriminate|clear H15]
      end.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; try discriminate
      end.
      match type of e with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in e; [clear e|]
      end.
      2: match type of e with
         | context [Z.eqb ?x ?y] =>
           destruct (Z.eqb_spec x y) in e; discriminate
         end.

      (* -- separate out cases of Kami execution *)
      dest_Zeqb.
      
      (* -- further simplification *)
      all: simpl_bit_manip.

      (** Evaluation of riscv-coq decode/execute *)
      
      all: eval_decode.
      all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
        try subst shamtHi; try subst shamtHiTest.
      all: eval_decodeI decodeI.
      
      (* -- evaluate the execution of riscv-coq *)
      5: match goal with
         | [decodeI := if ?x =? ?y then Lw _ _ _ else InvalidI |- _] =>
           destruct (Z.eqb_spec x y) in *
         end.
      all: subst dec; mcomp_step_in H5;
        repeat match goal with
               | H : False |- _ => case H
               | H : Z |- _ => clear H
               | H : list Instruction |- _ => clear H
               | H : Instruction |- _ => clear H
               end.

      (** Consistency proof for each instruction *)
      all: rt.

      all: unfold evalExpr in Heqic; fold evalExpr in Heqic.
      all: try match goal with
               | [H: match Memory.load_bytes ?sz ?m ?a with | Some _ => _ | None => _ end |- _] =>
                 destruct (Memory.load_bytes sz m a) as [lv|] eqn:Hlv
               end.

      all: try match goal with
               | [H: nonmem_load _ _ _ _ _ |- _] =>
                 destruct H as [? [[? ?] ?]]; discriminate
               end.
      6: { exfalso.
           subst v oimm12.
           destruct H13 as [? [? ?]].
           pose proof (conj H13 H15); clear H13 H15.
           regs_get_red H17.
           apply is_mmio_consistent in H17.
           setoid_rewrite H17 in Heqic.
           discriminate. }

      all: rt.
      all: eexists _, _.
      all: prove_KamiLabelR_silent.
      all: try subst regs; try subst kupd.

      all: prove_states_related.

      all: regs_get_red_goal.
      all: cbv [int8ToReg int16ToReg uInt8ToReg uInt16ToReg int32ToReg
                          MachineWidth_XLEN word.of_Z word WordsKami wordW KamiWord.word kofZ].
      all: subst v oimm12 rs1.
      all: regs_get_red Hlv.
      all: cbv [Utility.add
                  ZToReg MachineWidth_XLEN
                  word.add word WordsKami wordW KamiWord.word
                  word.of_Z kofZ] in Hlv;
        cbv [Memory.load_bytes] in Hlv;
        cbv [map.getmany_of_tuple
               Memory.footprint PrimitivePair.pair._1 PrimitivePair.pair._2
               HList.tuple.unfoldn HList.tuple.map HList.tuple.option_all] in Hlv.
      all: match goal with
           | [Hmr: mem_related _ _ _ |- _] => clear -Hlv Hmr
           end.
      all: match goal with
           | [Hmr: mem_related _ _ _ |- _] =>
             repeat (let bv := fresh "bv" in
                     let Hbv := fresh "Hbv" in
                     destruct (map.get _ _) as [bv|] eqn:Hbv in Hlv; [|discriminate];
                     match type of Hbv with
                     | map.get _ ?addr = Some _ => setoid_rewrite (Hmr addr) in Hbv
                     end;
                     destruct (_ <? _); [|discriminate];
                     apply Some_inv in Hbv; subst bv);
               apply Some_inv in Hlv; subst lv
           end.

      { (* lb *)
        rewrite split1_combine.
        cbv [combine PrimitivePair.pair._1 PrimitivePair.pair._2].
        rewrite Z.shiftl_0_l, Z.lor_0_r.
        rewrite byte.unsigned_of_Z.
        cbv [uwordToZ].
        rewrite byte_wrap_word_8.
        reflexivity.
      }

      { (* lh *)
        rewrite split1_combine_16.
        cbv [combine PrimitivePair.pair._1 PrimitivePair.pair._2].
        rewrite Z.shiftl_0_l, Z.lor_0_r.
        rewrite ?byte.unsigned_of_Z.
        cbv [uwordToZ]; rewrite ?byte_wrap_word_8.
        rewrite @kunsigned_combine_shiftl_lor with (sa:= 8%nat) (sb:= 8%nat).
        rewrite Z.lor_comm.
        reflexivity.
      }

      { (* lbu *)
        rewrite kami_evalZeroExtendTrunc by (cbv; Lia.lia).
        rewrite split1_combine.
        cbv [combine PrimitivePair.pair._1 PrimitivePair.pair._2].
        rewrite Z.shiftl_0_l, Z.lor_0_r.
        rewrite byte.unsigned_of_Z.
        cbv [uwordToZ].
        rewrite byte_wrap_word_8.
        reflexivity.
      }

      { (* lhu *)
        rewrite kami_evalZeroExtendTrunc by (cbv; Lia.lia).
        rewrite split1_combine_16.
        cbv [combine PrimitivePair.pair._1 PrimitivePair.pair._2].
        rewrite Z.shiftl_0_l, Z.lor_0_r.
        rewrite ?byte.unsigned_of_Z.
        cbv [uwordToZ]; rewrite ?byte_wrap_word_8.
        rewrite @kunsigned_combine_shiftl_lor with (sa:= 8%nat) (sb:= 8%nat).
        rewrite Z.lor_comm.
        reflexivity.
      }

      { (* lw *)
        cbv [combine PrimitivePair.pair._1 PrimitivePair.pair._2].
        rewrite Z.shiftl_0_l, Z.lor_0_r.
        rewrite ?byte.unsigned_of_Z.
        cbv [uwordToZ]; rewrite ?byte_wrap_word_8.

        change 8 with (Z.of_nat 8%nat).
        setoid_rewrite Z.lor_comm at 3.
        rewrite <-@kunsigned_combine_shiftl_lor with (sa:= 8%nat) (sb:= 8%nat).
        setoid_rewrite Z.lor_comm at 2.
        rewrite <-@kunsigned_combine_shiftl_lor with (sa:= 8%nat) (sb:= 16%nat).
        setoid_rewrite Z.lor_comm.
        rewrite <-@kunsigned_combine_shiftl_lor with (sa:= 8%nat) (sb:= 24%nat).

        match goal with
        | |- ?lw = ZToWord _ (signExtend _ (Z.of_N (wordToN ?rw))) =>
          set (v:= lw); replace rw with v
        end.
        { clearbody v.
          setoid_rewrite <-kami_evalSignExtendTrunc; [|cbv; Lia.lia].
          apply eq_sym, kami_evalSignExtendTrunc_32.
        }
        { subst v.
          repeat f_equal.
          apply wordToZ_inj.
          apply wordToZ_combine_WO.
        }
      }

      (** FIXME: [Qed] takes forever.. *)
  Admitted.

  Lemma kamiStep_sound_case_execLdZ:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "execLdZ"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      exists rm2 t,
        KamiLabelR
          {| annot := Some (Some "execLdZ"%string);
             defs := FMap.M.empty _;
             calls := cs |} t /\
        states_related (FMap.M.union kupd km1, t ++ t0) rm2 /\ post rm2.
  Proof.
    intros.
    match goal with
    | [H: states_related _ _ |- _] => inversion H; subst; clear H
    end.
    kinvert_more.
    kinv_action_dest_nosimpl.
    3: (* store (contradiction) *) exfalso; clear -Heqic0; discriminate.

    - (** MMIO-load *)
      block_subst kupd.
      red_regmap.
      red_trivial_conds.
      cleanup_trivial.
      unblock_subst kupd.

      (** Evaluate (invert) the two fetchers *)
      rt. eval_kami_fetch. rt.

      (** Begin symbolic evaluation of Kami decode/execute *)
      kami_cbn_all.
      kami_struct_cbv Heqic.
      kami_struct_cbv H.

      (* -- pick the subterm for the Kami instruction *)
      match goal with
      | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
      end.
      repeat
        match goal with
        | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
        | [ |- context [instrMem ?ipc] ] => change (instrMem ipc) with kinst
        end.
      clearbody kinst.

      (* -- pick the nextPc function *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
        remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
      end.
      kami_cbn_hint Heqnpc rv32NextPc.

      weq_to_Zeqb.

      (* -- eliminate trivially contradictory cases *)
      match type of H15 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H15; [clear H15|discriminate]
      end.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; [clear H14|discriminate]
      end.
      match type of e0 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in e0; [clear e0|]
      end.
      2: match type of e0 with
         | context [Z.eqb ?x ?y] =>
           destruct (Z.eqb_spec x y) in e0; discriminate
         end.

      (* -- separate out cases of Kami execution *)
      dest_Zeqb.
      
      (* -- further simplification *)
      simpl_bit_manip.

      (** Evaluation of riscv-coq decode/execute *)
      eval_decode.

      try subst opcode; try subst funct3; try subst funct6; try subst funct7;
        try subst shamtHi; try subst shamtHiTest.
      eval_decodeI decodeI.

      (* -- Kami does not try to further decode the target instruction when the
       * opcode is [opcode_LOAD] and the destination register is [r0].
       * But riscv-coq always requires a complete decode, so we manually do the
       * case analysis. *)
      subst decodeI resultI results.
      repeat match type of Hdec with
             | context [?x =? ?y] => destruct (Z.eqb_spec x y) in Hdec
             end.
      
      (* -- evaluate the execution of riscv-coq *)
      all: subst dec; mcomp_step_in H5;
        repeat match goal with
               | H : False |- _ => case H
               | H : Z |- _ => clear H
               | H : list Instruction |- _ => clear H
               | H : Instruction |- _ => clear H
               end.

      (** Consistency proof for each instruction *)
      all: rt.

      all: unfold evalExpr in Heqic; fold evalExpr in Heqic.
      all: try match goal with
               | [H: match Memory.load_bytes ?sz ?m ?a with | Some _ => _ | None => _ end |- _] =>
                 destruct (Memory.load_bytes sz m a) as [lv|] eqn:Hlv; [exfalso|]
               end.
      all: try (subst v oimm12;
                regs_get_red Hlv;
                match goal with
                | [Heqic: true = evalExpr (isMMIO _ _) |- _] =>
                  apply eq_sym, is_mmio_consistent in Heqic;
                  destruct Heqic as [Heqic _];
                  eapply mem_related_load_bytes_Some in Hlv; [|eassumption|discriminate];
                  clear -Heqic Hlv Hkmemdisj;
                  eapply mmio_mem_disjoint; eassumption
                end).

      all: match goal with
           | [H: nonmem_load _ _ _ _ _ |- _] =>
             let Hpost := fresh "H" in destruct H as [? [? Hpost]]
           end.
      all: try match goal with
               | [H: isMMIOAligned _ _ |- _] =>
                 exfalso; clear -H; destruct H as [? ?]; discriminate
               end.
      specialize (H14 (split 4 (wordToZ (x9 Fin.F1)))).
      
      rt.
      eexists _, _.
      prove_KamiLabelR_mmio.
      try subst regs; try subst kupd.

      prove_states_related.
      { kami_struct_cbv_goal; cbn [evalExpr evalConstT].
        subst v oimm12.
        regs_get_red_goal.
        constructor; [|assumption].
        apply events_related_mmioLoadEvent.
        { rewrite kami_evalZeroExtendTrunc_32.
          rewrite kami_evalSignExtendTrunc by (cbv; Lia.lia).
          rewrite unsigned_split2_as_bitSlice.
          reflexivity.
        }
        { apply signExtend_combine_split_signed. }
      }

    - (** load *)
      block_subst kupd.
      red_regmap.
      red_trivial_conds.
      cleanup_trivial.
      unblock_subst kupd.

      (** Evaluate (invert) the two fetchers *)
      rt. eval_kami_fetch. rt.

      (** Symbolic evaluation of Kami decode/execute *)
      clear Heqic0.
      kami_cbn_all.
      kami_struct_cbv Heqic.
      kami_struct_cbv H.

      (* -- pick the subterm for the Kami instruction *)
      match goal with
      | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
      end.
      repeat
        match goal with
        | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
        end.
      clearbody kinst.

      (* -- pick the nextPc function *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
        remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
      end.
      kami_cbn_hint Heqnpc rv32NextPc.

      (* -- eliminate trivially contradictory cases *)
      weq_to_Zeqb.
      match type of H15 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H15; [clear H15|discriminate]
      end.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; try discriminate
      end.
      match type of e0 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in e0; [clear e0|]
      end.
      2: match type of e0 with
         | context [Z.eqb ?x ?y] =>
           destruct (Z.eqb_spec x y) in e0; discriminate
         end.

      (* -- separate out cases of Kami execution *)
      dest_Zeqb.
      
      (* -- further simplification *)
      all: simpl_bit_manip.

      (** Evaluation of riscv-coq decode/execute *)
      
      all: eval_decode.
      all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
        try subst shamtHi; try subst shamtHiTest.
      all: eval_decodeI decodeI.

      (* -- Kami does not try to further decode the target instruction when the
       * opcode is [opcode_LOAD] and the destination register is [r0].
       * But riscv-coq always requires a complete decode, so we manually do the
       * case analysis. *)
      subst decodeI resultI results.
      repeat match type of Hdec with
             | context [?x =? ?y] => destruct (Z.eqb_spec x y) in Hdec
             end.
      
      (* -- evaluate the execution of riscv-coq *)
      all: subst dec; mcomp_step_in H5;
        repeat match goal with
               | H : False |- _ => case H
               | H : Z |- _ => clear H
               | H : list Instruction |- _ => clear H
               | H : Instruction |- _ => clear H
               end.

      (** Consistency proof for each instruction *)
      all: rt.

      all: unfold evalExpr in Heqic; fold evalExpr in Heqic.
      all: try match goal with
               | [H: match Memory.load_bytes ?sz ?m ?a with | Some _ => _ | None => _ end |- _] =>
                 destruct (Memory.load_bytes sz m a) as [lv|] eqn:Hlv
               end.

      all: try match goal with
               | [H: nonmem_load _ _ _ _ _ |- _] =>
                 destruct H as [? [[? ?] ?]]; discriminate
               end.
      4: { exfalso.
           subst v oimm12.
           destruct H13 as [? [? ?]].
           pose proof (conj H13 H15); clear H13 H15.
           regs_get_red H17.
           apply is_mmio_consistent in H17.
           setoid_rewrite H17 in Heqic.
           discriminate. }

      all: rt.
      all: eexists _, _.
      all: prove_KamiLabelR_silent.
      all: try subst regs; try subst kupd.
      all: prove_states_related.

      (** FIXME: [Qed] takes forever.. *)
  Admitted.
  
  Lemma kamiStep_sound_case_execSt:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "execSt"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      exists rm2 t,
        KamiLabelR
          {| annot := Some (Some "execSt"%string);
             defs := FMap.M.empty _;
             calls := cs |} t /\
        states_related (FMap.M.union kupd km1, t ++ t0) rm2 /\ post rm2.
  Proof.
    intros.
    match goal with
    | [H: states_related _ _ |- _] => inversion H; subst; clear H
    end.
    kinvert_more.
    kinv_action_dest_nosimpl.
    2: (* load (contradiction) *) exfalso; clear -Heqic0; discriminate.

    - (** MMIO-store *)
      block_subst kupd.
      red_regmap.
      red_trivial_conds.
      cleanup_trivial.
      unblock_subst kupd.

      (** Evaluate (invert) the two fetchers *)
      rt. eval_kami_fetch. rt.

      (** Begin symbolic evaluation of Kami decode/execute *)
      kami_cbn_all.
      kami_struct_cbv Heqic.
      kami_struct_cbv H.

      (* -- pick the subterm for the Kami instruction *)
      match goal with
      | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
      end.
      repeat
        match goal with
        | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
        | [ |- context [instrMem ?ipc] ] => change (instrMem ipc) with kinst
        end.
      clearbody kinst.

      (* -- pick the nextPc function *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
        remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
      end.
      kami_cbn_hint Heqnpc rv32NextPc.

      weq_to_Zeqb.

      (* -- eliminate trivially contradictory cases *)
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; [discriminate|]
      end.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; [clear H14|discriminate]
      end.
      match type of e with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in e; [clear e|discriminate]
      end.

      (* -- separate out cases of Kami execution *)
      dest_Zeqb.

      (* -- further simplification *)
      all: simpl_bit_manip.

      (** Evaluation of riscv-coq decode/execute *)
      
      all: eval_decode.
      all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
        try subst shamtHi; try subst shamtHiTest.
      all: eval_decodeI decodeI.
      
      (* -- evaluate the execution of riscv-coq *)
      3: match goal with
         | [decodeI := if ?x =? ?y then Sw _ _ _ else InvalidI |- _] =>
           destruct (Z.eqb_spec x y) in *
         end.
      all: subst dec; mcomp_step_in H5;
        repeat match goal with
               | H : False |- _ => case H
               | H : Z |- _ => clear H
               | H : list Instruction |- _ => clear H
               | H : Instruction |- _ => clear H
               end.

      (** Consistency proof for each instruction *)
      all: rt.

      all: unfold evalExpr in Heqic; fold evalExpr in Heqic.
      all: try match goal with
               | [H: match Memory.store_bytes ?sz ?m ?a ?v with
                     | Some _ => _ | None => _ end |- _] =>
                 destruct (Memory.store_bytes sz m a v) eqn:Hst; [exfalso|]
               end.

      all: rewrite @kunsigned_combine_shiftl_lor with (sa:= 5%nat) (sb:= 7%nat) in *.
      all: simpl_bit_manip.

      all: try (subst v simm12;
                regs_get_red Hst;
                cbv [Memory.store_bytes] in Hst;
                destruct (Memory.load_bytes _ _ _) eqn:Hlv in Hst; [clear Hst|discriminate];
                match goal with
                | [Heqic: true = evalExpr (isMMIO _ _) |- _] =>
                  apply eq_sym, is_mmio_consistent in Heqic;
                  destruct Heqic as [Heqic _];
                  eapply mem_related_load_bytes_Some in Hlv; [|eassumption|discriminate];
                  clear -Heqic Hlv Hkmemdisj;
                  eapply mmio_mem_disjoint; eassumption
                end).

      all: match goal with
           | [H: nonmem_store _ _ _ _ _ _ |- _] => destruct H as [? [? ?]]
           end.
      all: try match goal with
               | [H: isMMIOAligned _ _ |- _] =>
                 exfalso; clear -H; destruct H as [? ?]; discriminate
               end.

      rt.
      eexists _, _.
      prove_KamiLabelR_mmio.
      try subst regs; try subst kupd.

      prove_states_related.
      { kami_struct_cbv_goal; cbn [evalExpr evalConstT].
        subst v simm12.
        regs_get_red_goal.
        constructor; [|assumption].
        apply events_related_mmioStoreEvent.
        { rewrite kami_evalZeroExtendTrunc_32.
          rewrite kami_evalSignExtendTrunc_32.
          rewrite kami_evalSignExtendTrunc by (cbv; Lia.lia).
          rewrite @kunsigned_combine_shiftl_lor with (sa:= 5%nat) (sb:= 7%nat).
          rewrite unsigned_split2_split1_as_bitSlice.
          rewrite unsigned_split2_as_bitSlice.
          reflexivity.
        }
        { subst v0; regs_get_red_goal.
          cbv [regToInt32
                 MachineWidth_XLEN word.unsigned word WordsKami wordW KamiWord.word kofZ].
          setoid_rewrite signExtend_combine_split_unsigned.
          reflexivity.
        }
      }
      { intros _.
        do 4 apply RiscvXAddrsSafe_removeXAddr_sound.
        assumption.
      }

    - (** store *)
      block_subst kupd.
      red_regmap.
      red_trivial_conds.
      cleanup_trivial.
      unblock_subst kupd.

      (** Evaluate (invert) the two fetchers *)
      rt. eval_kami_fetch. rt.

      (** Symbolic evaluation of Kami decode/execute *)
      clear Heqic0.
      kami_cbn_all.
      kami_struct_cbv Heqic.
      kami_struct_cbv H.

      (* -- pick the subterm for the Kami instruction *)
      match goal with
      | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
      end.
      repeat
        match goal with
        | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
        end.
      clearbody kinst.

      (* -- pick the nextPc function *)
      match goal with
      | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
        remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
      end.
      kami_cbn_hint Heqnpc rv32NextPc.

      (* -- eliminate trivially contradictory cases *)
      weq_to_Zeqb.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; [discriminate|]
      end.
      match type of H14 with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in H14; [clear H14|discriminate]
      end.
      match type of e with
      | context [Z.eqb ?x ?y] =>
        destruct (Z.eqb_spec x y) in e; [clear e|discriminate]
      end.

      (* -- separate out cases of Kami execution *)
      dest_Zeqb.
      
      (* -- further simplification *)
      all: simpl_bit_manip.

      (** Evaluation of riscv-coq decode/execute *)
      
      all: eval_decode.
      all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
        try subst shamtHi; try subst shamtHiTest.
      all: eval_decodeI decodeI.

      (* -- evaluate the execution of riscv-coq *)
      3: match goal with
         | [decodeI := if ?x =? ?y then Sw _ _ _ else InvalidI |- _] =>
           destruct (Z.eqb_spec x y) in *
         end.
      all: subst dec; mcomp_step_in H5;
        repeat match goal with
               | H : False |- _ => case H
               | H : Z |- _ => clear H
               | H : list Instruction |- _ => clear H
               | H : Instruction |- _ => clear H
               end.

      (** Consistency proof for each instruction *)
      all: rt.

      all: unfold evalExpr in Heqic; fold evalExpr in Heqic.
      all: try match goal with
               | [H: match Memory.store_bytes ?sz ?m ?a ?v with
                     | Some _ => _ | None => _
                     end |- _] =>
                 destruct (Memory.store_bytes sz m a v) as [nmem|] eqn:Hnmem
               end.

      all: rewrite @kunsigned_combine_shiftl_lor with (sa:= 5%nat) (sb:= 7%nat) in *.
      all: simpl_bit_manip.

      all: try match goal with
               | [H: nonmem_store _ _ _ _ _ _ |- _] =>
                 destruct H as [? [[? ?] ?]]; discriminate
               end.
      4: { exfalso.
           subst v simm12.
           destruct H5 as [? [? ?]].
           pose proof (conj H5 H13); clear H5 H13.
           regs_get_red H15.
           apply is_mmio_consistent in H15.
           setoid_rewrite H15 in Heqic.
           discriminate. }

      all: rt.
      all: eexists _, _.
      all: prove_KamiLabelR_silent.
      all: try subst regs; try subst kupd.

      (* -- solve trivial goals first *)
      all: rewrite memStoreBytes'_updateBytes;
        cbv [updateBytes evalExpr evalArray evalConstT Vector.map natToFin Nat.sub].
      all: prove_states_related.

      (* -- prove [RiscvXAddrsSafe] after store *)
      all: subst v simm12 rs1 v0.
      all: regs_get_red_goal; regs_get_red Hnmem.

      all: cbv [Memory.store_bytes] in Hnmem;
        match type of Hnmem with
        | match ?olv with | Some _ => _ | None => _ end = _ =>
          destruct olv eqn:Hlv; [|discriminate]
        end;
        apply Some_inv in Hnmem; subst nmem;
          cbv [Memory.unchecked_store_bytes
                 map.putmany_of_tuple
                 Memory.footprint PrimitivePair.pair._1 PrimitivePair.pair._2
                 HList.tuple.unfoldn].
      all: pose proof Hlv as Hlv';
        eapply mem_related_load_bytes_Some in Hlv'; [|eassumption|discriminate].

      (* -- prove preservation of [RiscvXAddrsSafe] for {sb, sh, sw} *)

      1: { (* [RiscvXAddrsSafe] for "sb" *)
        intros _.
        repeat apply RiscvXAddrsSafe_removeXAddr_write_ok; assumption.
      }
      2: { (* [RiscvXAddrsSafe] for "sh" *)
        intros _.
        cbv [Memory.load_bytes
               map.getmany_of_tuple
               HList.tuple.option_all HList.tuple.map HList.tuple.unfoldn
               Memory.footprint PrimitivePair.pair._1 PrimitivePair.pair._2] in Hlv.
        repeat (destruct_one_match_hyp; [|discriminate]).
        erewrite H12 in E1.
        destruct_one_match_hyp; [|discriminate].
        repeat apply RiscvXAddrsSafe_removeXAddr_write_ok; assumption.
      }
      3: { (* [RiscvXAddrsSafe] for "sw" *)
        intros _.
        cbv [Memory.load_bytes
               map.getmany_of_tuple
               HList.tuple.option_all HList.tuple.map HList.tuple.unfoldn
               Memory.footprint PrimitivePair.pair._1 PrimitivePair.pair._2] in Hlv.
        repeat (destruct_one_match_hyp; [|discriminate]).
        erewrite H12 in E1, E3, E5.
        repeat (destruct_one_match_hyp; [|discriminate]).
        repeat apply RiscvXAddrsSafe_removeXAddr_write_ok; assumption.
      }

      (* -- prove preservation of [mem_related] for {sb, sh, sw} *)
      all: apply mem_related_put; [|assumption
                                   |cbv [word.unsigned];
                                    setoid_rewrite <-kunsigned_byte_split1;
                                    reflexivity].

      { (* sb *) assumption. }
      { (* sh *)
        apply mem_related_put.
        { assumption. }
        { clear -Hlv H12. (* mem_related *)
          cbv [Memory.load_bytes
                 map.getmany_of_tuple
                 HList.tuple.option_all HList.tuple.map HList.tuple.unfoldn
                 Memory.footprint PrimitivePair.pair._1 PrimitivePair.pair._2] in Hlv.
          repeat (destruct_one_match_hyp; [|discriminate]).
          erewrite H12 in E1.
          destruct_one_match_hyp; [|discriminate].
          assumption.
        }
        { cbv [word.unsigned].
          setoid_rewrite <-kunsigned_byte_split1.
          rewrite ?kunsigned_split2_shiftr.
          reflexivity.
        }
      }
      { (* sw *)
        repeat (apply mem_related_put;
                [| |cbv [word.unsigned];
                    setoid_rewrite <-kunsigned_byte_split1;
                    rewrite ?kunsigned_split2_shiftr;
                    reflexivity]).
        1: assumption.
        all: cbv [word.add word WordsKami wordW KamiWord.word word.of_Z kofZ].
        all: match goal with
             | [Hmr: mem_related _ _ _ |- _] => clear -Hlv Hmr
             end.
        all: cbv [Memory.load_bytes
                    map.getmany_of_tuple
                    HList.tuple.option_all HList.tuple.map HList.tuple.unfoldn
                    Memory.footprint PrimitivePair.pair._1 PrimitivePair.pair._2] in Hlv.
        all: repeat (destruct_one_match_hyp; [|discriminate]).
        { erewrite H12 in E5.
          destruct_one_match_hyp; [assumption|discriminate].
        }
        { erewrite H12 in E3.
          destruct_one_match_hyp; [assumption|discriminate].
        }          
        { erewrite H12 in E1.
          destruct_one_match_hyp; [assumption|discriminate].
        }
      }

      (** FIXME: [Qed] takes forever.. *)
  Admitted.

  Lemma kamiStep_sound_case_execNm:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "execNm"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      exists rm2 t,
        KamiLabelR
          {| annot := Some (Some "execNm"%string);
             defs := FMap.M.empty _;
             calls := cs |} t /\
        states_related (FMap.M.union kupd km1, t ++ t0) rm2 /\ post rm2.
  Proof.
    intros.
    match goal with
    | [H: states_related _ _ |- _] => inversion H; subst; clear H
    end.

    kinvert_more.
    kinv_action_dest_nosimpl.
    block_subst kupd.
    red_regmap.
    red_trivial_conds.
    cleanup_trivial.
    unblock_subst kupd.

    (** Evaluate (invert) the two fetchers *)
    rt. eval_kami_fetch. rt.

    (** Symbolic evaluation of Kami decode/execute *)
    kami_cbn_all.

    (* -- pick the subterm for the Kami instruction *)
    match goal with
    | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
    end.
    repeat
      match goal with
      | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
      end.
    clearbody kinst.

    (* -- pick the execution function for simplification *)
    match goal with
    | [H: context [@evalExpr ?fk (rv32DoExec ?sz ?ty ?rs1 ?rs2 ?pc ?inst)] |- _] =>
      remember (@evalExpr fk (rv32DoExec sz ty rs1 rs2 pc inst)) as execVal
    end.
    kami_cbn_hint HeqexecVal rv32DoExec.
    
    (* -- pick the nextPc function *)
    match goal with
    | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
      remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
    end.
    kami_cbn_hint Heqnpc rv32NextPc.

    (* -- separate out cases of Kami execution *)
    weq_to_Zeqb.
    dest_Zeqb.

    (* -- filter out load/store/branch instructions (not handled by [execNm]) *)
    all: try match goal with
             | [H: negb (kunsigned $0 =? 0) = true |- _] => exfalso; clear -H; discriminate
             | [H: (kunsigned opLd =? _) = true |- _] => exfalso; clear -H; discriminate
             | [H: (kunsigned opSt =? _) = true |- _] => exfalso; clear -H; discriminate
             end.

    (* -- further simplification *)
    all: simpl_bit_manip.

    (** Evaluation of riscv-coq decode/execute *)

    all: eval_decode.
    all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
      try subst shamtHi; try subst shamtHiTest.
    all: eval_decodeI decodeI.

    (* -- evaluate the execution of riscv-coq *)

    (* Fence and CSR instructions: contradiction either in decode or execute *)
    42: (subst rd decodeI decodeCSR resultI resultCSR results;
         match type of H15 with (* derived from [rd <> 0] in [execNm] *)
         | negb (?x =? ?y) = true => destruct (Z.eqb_spec x y) in *; [discriminate|]
         end;
         repeat rewrite Bool.andb_false_r in Hdec; cbn in Hdec;
         dest_Zeqb; cbn in Hdec).

    (* Cases that require additional simplification to draw [False] 
     * by [mcomp_step_in]. *)
    40,41: (subst decodeI resultI results;
            repeat rewrite Bool.andb_false_r in Hdec; cbn in Hdec).

    all: subst dec; mcomp_step_in H5;
      repeat match goal with
             | H : False |- _ => case H
             | H : Z |- _ => clear H
             | H : list Instruction |- _ => clear H
             | H : Instruction |- _ => clear H
             end.

    (** Consistency proof for each instruction *)
    all: rt.
    all: eexists _, _.
    all: prove_KamiLabelR_silent.

    all:
      repeat match goal with
             | H : negb ?x = true |- _ => eapply Bool.negb_true_iff in H
             | H : Z.eqb _ _ = true |- _ => eapply Z.eqb_eq in H
             | H : Z.eqb _ _ = false |- _ => eapply Z.eqb_neq in H
             end;
      try (case (Z.eq_dec rd Register0) as [X|_];
           [match goal with H : bitSlice (kunsigned _) 7 12 <> _ |- _ => case (H X) end|]).
    all: try subst regs; try subst kupd.

    (** Proving simulation; solve trivial goals first *)

    all: prove_states_related.

    all: match goal with | H: pc_related ?kpc _ |- _ => red in H; subst kpc end.
    all: try reflexivity.

    (* -- remaining [pc_related] proofs *)

    { (* [pc_related_and_valid] for `JAL` *)
      subst newPC jimm20.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].

      repeat f_equal.
      case TODO_word.
    }

    { (* [pc_related_and_valid] for `JALR` *)
      subst newPC oimm12 v rs1.
      split; [apply AddrAligned_consistent; assumption|red].
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      regs_get_red_goal.
      case TODO_word.
    }

    (* -- proof per an instruction execution *)
    all: try match goal with
             | [H: _ {| getMachine := _ |} |- _] => clear H
             end.
    all: try subst val; cbv [ZToReg MachineWidth_XLEN]; cbn [evalBinBitBool].
    all: eapply (@word.unsigned_inj _ (@word (@WordsKami width width_cases)) _).
    all: rewrite <-?ZToWord_Z_of_N.
    all: change (ZToWord 32) with (@word.of_Z 32 (@word (@WordsKami width width_cases))).
    all: rewrite ?word.unsigned_of_Z.

    { (* lui *)
      clear.
      match goal with
      | |- context[@word.unsigned ?a ?b ?x] =>
        change (@word.unsigned a b x) with (Z.of_N (wordToN x))
      end.
      rewrite wordToN_combine.
      change (wordToN (ZToWord 12 0) ) with 0%N.
      rewrite N.add_0_l.
      cbv [word.wrap].
      cbv [imm20].
      rewrite N2Z.inj_mul.
      change (Z.of_N (NatLib.Npow2 12)) with (2^12)%Z.
      rewrite unsigned_split2_as_bitSlice.
      t.
      change ((Z.of_nat 12)) with 12%Z.
      rewrite Z.shiftl_mul_pow2 by blia.
      cbv [kunsigned].
      change (12 + 20)%nat with 32%nat.
      change (Z.to_nat 32) with 32%nat.
      set (x := bitSlice (Z.of_N (@wordToN 32 kinst)) 12 32).
      change Utility.width with 32.
      cbv [signExtend].
      change (2 ^ (32 - 1)) with (2^31).
      rewrite Zminus_mod_idemp_l.
      replace (x * 2 ^ 12 + 2 ^ 31 - 2 ^ 31) with (x * 2 ^ 12) by blia.
      rewrite Z.mod_small; try ring.
      pose proof bitSlice_range_ex (Z.of_N (@wordToN 32 kinst)) 12 32.
      blia.
    }

    { (* auipc *)
      clear.
      subst oimm20.
      unfold Utility.add.
      eapply f_equal.
      rewrite wplus_comm; eapply f_equal2; [|reflexivity].
      rewrite signExtend_word_of_Z_nop.
      eapply (@word.unsigned_inj _ (@word (@WordsKami width width_cases)) _).
      match goal with
      | |- context[@word.unsigned ?a ?b ?x] =>
        change (@word.unsigned a b x) with (Z.of_N (wordToN x))
      end.
      rewrite Z_of_wordToN_combine_alt.
      change (Z.of_N (wordToN (ZToWord 12 0))) with 0%Z.
      rewrite Z.lor_0_l.
      rewrite unsigned_split2_as_bitSlice.
      t.
      change (Z.of_nat 12) with 12.
      change (Z.of_N (N.of_nat 12)) with 12.
      rewrite word.unsigned_of_Z; cbv [word.wrap]; symmetry; eapply Z.mod_small.
      pose proof bitSlice_range_ex (Z.of_N (@wordToN 32 kinst)) 12 32 ltac:(blia).
      rewrite Z.shiftl_mul_pow2 by blia.
      change Utility.width with 32.
      change (12 + 20)%nat with 32%nat.
      change (2^32) with (2^(32-12) * 2^12).
      blia.
    }

    { (* slli *)
      subst v shamt6 rs1.
      regs_get_red_goal.
      clear -e2.
      cbv [machineIntToShamt id].
      match goal with
      | [ |- context [bitSlice ?w ?a ?b] ] =>
        replace (bitSlice w a b)
          with (Z.of_N (wordToN (split2 20 5 (split1 (20 + 5) 7 kinst))))
          by ((* Provable with [e2] *)
              rewrite unsigned_split2_split1_as_bitSlice;
              case TODO_word)
      end.
      case TODO_word. (* consistency between `wlshift` and `sll` *)
    }

    { (* srli *)
      subst v shamt6 rs1.
      regs_get_red_goal.
      clear -e2.
      cbv [machineIntToShamt id].
      match goal with
      | [ |- context [bitSlice ?w ?a ?b] ] =>
        replace (bitSlice w a b)
          with (Z.of_N (wordToN (split2 20 5 (split1 (20 + 5) 7 kinst))))
          by case TODO_word
      end.
      case TODO_word. (* consistency between `wrshift` and `srl` *)
    }

    { (* srai *)
      subst v shamt6 rs1.
      regs_get_red_goal.
      clear -e2.
      cbv [machineIntToShamt id].
      match goal with
      | [ |- context [bitSlice ?w ?a ?b] ] =>
        replace (bitSlice w a b)
          with (Z.of_N (wordToN (split2 20 5 (split1 (20 + 5) 7 kinst))))
          by case TODO_word
      end.
      case TODO_word. (* consistency between `wrshifta` and `sra` *)
    }

    { (* sll *)
      subst v v0 rs1 rs2.
      regs_get_red_goal.
      cbv [regToShamt].
      case TODO_word. (* consistency between `wlshift` and `sll` *)
    }

    { (* srl *)
      subst v v0 rs1 rs2.
      regs_get_red_goal.
      cbv [regToShamt].
      case TODO_word. (* consistency between `wrshift` and `srl` *)
    }

    { (* sra *)
      subst v v0 rs1 rs2.
      regs_get_red_goal.
      cbv [regToShamt].
      case TODO_word. (* consistency between `wrshifta` and `sra` *)
    }

    all: idtac "KamiRiscv: [kamiStep_sound_case_execNm] starting the Qed...".
  (*A lot of*) Time Qed.

  Lemma kamiStep_sound_case_execNmZ:
    forall km1 t0 rm1 post kupd cs
           (Hkinv: scmm_inv (Z.to_nat memSizeLg) rv32RfIdx rv32Fetch km1),
      states_related (km1, t0) rm1 ->
      mcomp_sat_unit (run1 iset) rm1 post ->
      Step kamiProc km1 kupd
           {| annot := Some (Some "execNmZ"%string);
              defs := FMap.M.empty _;
              calls := cs |} ->
      exists rm2 t,
        KamiLabelR
          {| annot := Some (Some "execNmZ"%string);
             defs := FMap.M.empty _;
             calls := cs |} t /\
        states_related (FMap.M.union kupd km1, t ++ t0) rm2 /\ post rm2.
  Proof.
    intros.
    match goal with
    | [H: states_related _ _ |- _] => inversion H; subst; clear H
    end.

    kinvert_more.
    kinv_action_dest_nosimpl.
    block_subst kupd.
    red_regmap.
    red_trivial_conds.
    cleanup_trivial.
    unblock_subst kupd.

    (** Evaluate (invert) the two fetchers *)
    rt. eval_kami_fetch. rt.

    (** Symbolic evaluation of Kami decode/execute *)
    kami_cbn_all.

    (* -- pick the subterm for the Kami instruction *)
    match goal with
    | [H: context [instrMem ?ipc] |- _] => set (kinst:= instrMem ipc)
    end.
    repeat
      match goal with
      | [H: context [instrMem ?ipc] |- _] => change (instrMem ipc) with kinst in H
      end.
    clearbody kinst.

    (* -- [execNmZ] does no execution; just pick the nextPc function *)
    match goal with
    | [H: context [@evalExpr ?fk (rv32NextPc ?sz ?ty ?rf ?pc ?inst)] |- _] =>
      remember (@evalExpr fk (rv32NextPc sz ty rf pc inst)) as npc
    end.
    kami_cbn_hint Heqnpc rv32NextPc.

    weq_to_Zeqb.
    dest_Zeqb.

    (* -- filter out load/store instructions (not handled by [execNm]) *)
    all: try match goal with
             | [H: (kunsigned opLd =? _) = true |- _] => exfalso; clear -H; discriminate
             | [H: (kunsigned opSt =? _) = true |- _] => exfalso; clear -H; discriminate
             end.

    (* -- further simplification *)
    all: simpl_bit_manip.

    (** Evaluation of riscv-coq decode/execute *)

    all: eval_decode.
    all: try subst opcode; try subst funct3; try subst funct6; try subst funct7;
      try subst shamtHi; try subst shamtHiTest.
    all: eval_decodeI decodeI.

    (* -- Kami does not try to further decode the target instruction when the
     * opcode is [opcode_OP] and the destination register is [r0].
     * But riscv-coq always requires a complete decode, so we manually do the
     * case analysis. *)
    11: (match type of H15 with (* derived from [rd <> 0] in [execNm] *)
         | (?x =? ?y) = true => destruct (Z.eqb_spec x y) in *; [|discriminate]
         end;
         subst rd decodeI decodeCSR resultI resultCSR results;
         (* It takes too much time to just use [dest_Zeqb] with [Hdec],
          * thus we manually do case analysis first by destructing `opcode`
          * and then by the other fields. *)
         repeat
           match type of Hdec with
           | context [Z.eqb (bitSlice _ 0 7) ?c] =>
             destruct (Z.eqb_spec
                         (bitSlice
                            (kunsigned (width:= Zpos (xO (xO (xO (xO (xO xH)))))) kinst)
                            0 7) c)
           end;
         repeat match goal with
                | [H: ?x = ?a, G: ?x = ?b |- _] =>
                  let aa := eval cbv in a in
                  let bb := eval cbv in b in
                  let t := isZcst aa in constr_eq t true;
                  let t := isZcst bb in constr_eq t true;
                  assert_fails (constr_eq aa bb);
                  exfalso; remember x; clear -H G;
                  cbv in H; cbv in G; rewrite H in G; inversion G
                end;
         repeat rewrite ?Bool.andb_true_l, ?Bool.andb_false_l in Hdec; cbn in Hdec;
         repeat
           match type of Hdec with
           | context [if ?c then _ else _] => destruct c
           end).
    
    (* -- evaluate the execution of riscv-coq *)
    all: subst dec; mcomp_step_in H5;
      repeat match goal with
             | H : False |- _ => case H
             | H : Z |- _ => clear H
             | H : list Instruction |- _ => clear H
             | H : Instruction |- _ => clear H
             end.

    (** Consistency proof for each instruction *)
    all: rt.
    all: eexists _, _.
    all: prove_KamiLabelR_silent.

    all:
      repeat match goal with
             | H : negb ?x = true |- _ => eapply Bool.negb_true_iff in H
             | H : Z.eqb _ _ = true |- _ => eapply Z.eqb_eq in H
             | H : Z.eqb _ _ = false |- _ => eapply Z.eqb_neq in H
             end;
      try (case (Z.eq_dec rd Register0) as [X|_];
           [match goal with H : bitSlice (kunsigned _) 7 12 <> _ |- _ => case (H X) end|]).
    all: try subst regs; try subst kupd.

    (** Proving simulation; solve trivial goals first *)

    all: prove_states_related.
    all: match goal with | H: pc_related ?kpc _ |- _ => red in H; subst kpc end.

    (* -- prove [regs_related] to write to r0 *)
    all: try match goal with
             | [rd := ?bs, Hbs: ?bs = 0 |- regs_related _ _] =>
               subst rd; rewrite Hbs; assumption
             end.

    (* -- remaining [pc_related] proofs *)

    { (* jal *)
      subst newPC jimm20.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      repeat f_equal.
      case TODO_word.
    }

    { (* jalr *)
      subst newPC oimm12 v rs1.
      split; [apply AddrAligned_consistent; assumption|red].
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      regs_get_red_goal.
      case TODO_word.
    }

    { (* beq(eq) *)
      subst newPC sbimm12.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      repeat f_equal.
      case TODO_word.
    }
    
    { (* beq(eq-neq contradiction) *)
      exfalso; subst v v0 rs1 rs2.
      regs_get_red E.
      apply N2Z.inj, wordToN_inj in e1; auto.
    }
    
    { (* beq(eq-neq contradiction) *)
      exfalso; subst v v0 rs1 rs2.
      regs_get_red E; congruence.
    }

    { (* bne(neq) *)
      match goal with
      | [ |- context [Z.eqb ?x ?y] ] => destruct (Z.eqb_spec x y)
      end.
      { exfalso; subst v v0 rs1 rs2.
        regs_get_red E.
        cbv [reg_eqb MachineWidth_XLEN word.eqb word WordsKami wordW KamiWord.word] in E.
        apply weqb_false in E.
        apply N2Z.inj, wordToN_inj in e1; auto.
      }
      { cbv [negb].
        subst addr sbimm12.
        split; [apply AddrAligned_consistent; assumption|].
        clear; red.
        cbv [Utility.add
               ZToReg MachineWidth_XLEN
               word.add word WordsKami wordW KamiWord.word
               word.of_Z kofZ].
        repeat f_equal.
        case TODO_word.
      }
    }

    { (* bne(eq) *)
      match goal with
      | [ |- context [Z.eqb ?x ?y] ] => destruct (Z.eqb_spec x y)
      end.
      { apply pc_related_plus4; red; eauto. }
      { exfalso; subst v v0 rs1 rs2.
        regs_get_red E.
        cbv [reg_eqb MachineWidth_XLEN word.eqb word WordsKami wordW KamiWord.word] in E.
        apply Bool.negb_false_iff in E; apply weqb_sound in E.
        congruence.
      }
    }

    { (* blt(lt) *)
      cbv [evalBinBitBool].
      cbv [signed_less_than
             MachineWidth_XLEN
             word.lts word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wslt_dec _ _); [|discriminate].
      subst addr sbimm12.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      repeat f_equal.
      case TODO_word.
    }

    { (* blt(not lt) *)
      cbv [evalBinBitBool].
      cbv [signed_less_than
             MachineWidth_XLEN
             word.lts word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wslt_dec _ _); [discriminate|].
      apply pc_related_plus4; red; eauto.
    }

    { (* bge(ge) *)
      cbv [evalBinBitBool].
      cbv [signed_less_than
             MachineWidth_XLEN
             word.lts word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wslt_dec _ _); [discriminate|].
      subst addr sbimm12.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      repeat f_equal.
      case TODO_word.
    }

    { (* bge(not ge) *)
      cbv [evalBinBitBool].
      cbv [signed_less_than
             MachineWidth_XLEN
             word.lts word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wslt_dec _ _); [|discriminate].
      apply pc_related_plus4; red; eauto.
    }

    { (* bltu(ltu) *)
      cbv [evalBinBitBool].
      cbv [ltu MachineWidth_XLEN
               word.ltu word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wlt_dec _ _); [|discriminate].
      subst addr sbimm12.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      repeat f_equal.
      case TODO_word.
    }

    { (* bltu(not ltu) *)
      cbv [evalBinBitBool].
      cbv [ltu MachineWidth_XLEN
               word.ltu word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wlt_dec _ _); [discriminate|].
      apply pc_related_plus4; red; eauto.
    }

    { (* bgeu(geu) *)
      cbv [evalBinBitBool].
      cbv [ltu MachineWidth_XLEN
               word.ltu word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wlt_dec _ _); [discriminate|].
      subst addr sbimm12.
      split; [apply AddrAligned_consistent; assumption|].
      clear; red.
      cbv [Utility.add
             ZToReg MachineWidth_XLEN
             word.add word WordsKami wordW KamiWord.word
             word.of_Z kofZ].
      repeat f_equal.
      case TODO_word.
    }

    { (* bgeu(not geu) *)
      cbv [evalBinBitBool].
      cbv [ltu MachineWidth_XLEN
               word.ltu word WordsKami wordW KamiWord.word] in E.
      subst v v0 rs1 rs2.
      regs_get_red E.
      destruct (wlt_dec _ _); [|discriminate].
      apply pc_related_plus4; red; eauto.
    }

    all: idtac "KamiRiscv: [kamiStep_sound_case_execNmZ] starting the Qed...".
  Time Qed.
  
  Lemma kamiStep_sound:
    forall (m1 m2: KamiMachine) (klbl: Kami.Semantics.LabelT)
           (m1': RiscvMachine) (t0: list Event) (post: RiscvMachine -> Prop)
           (Hkreach: Kami.Semantics.reachable m1 kamiProc),
      kamiStep m1 m2 klbl ->
      states_related (m1, t0) m1' ->
      mcomp_sat_unit (run1 iset) m1' post ->
      (* Three cases for each Kami step:
       * 1) riscv-coq does not proceed or
       * 2) both Kami and riscv-coq proceed, preserving [states_related]. *)
      (states_related (m2, t0) m1' /\ klbl.(calls) = FMap.M.empty _) \/
      exists m2' t,
        KamiLabelR klbl t /\ states_related (m2, t ++ t0) m2' /\ post m2'.
  Proof.
    intros.
    destruct H as [kupd [? ?]]; subst.
    assert (PHide (Step kamiProc m1 kupd klbl)) by (constructor; assumption).
    apply scmm_inv_ok in Hkreach; [|reflexivity|apply pgm_init_not_mmio].

    (* Since the processor is inlined thus there are no defined methods,
     * the step cases generated by [kinvert] are by rules.
     *)
    kinvert.

    - kami_step_case_empty.
    - kami_step_case_empty.
    - kinvert_pre; left; eapply kamiStep_sound_case_pgmInit; eauto.
    - kinvert_pre; left; eapply kamiStep_sound_case_pgmInitEnd; eauto.
    - kinvert_pre; right; eapply kamiStep_sound_case_execLd; eauto.
    - kinvert_pre; right; eapply kamiStep_sound_case_execLdZ; eauto.
    - kinvert_pre; right; eapply kamiStep_sound_case_execSt; eauto.
    - kinvert_pre; right; eapply kamiStep_sound_case_execNm; eauto.
    - kinvert_pre; right; eapply kamiStep_sound_case_execNmZ; eauto.
  Qed.

End Equiv.
