{
  repository,
  repositoryRevision,
  stageIndex,
  previousStage,
  nextStage,
  normalInputContract,
}:

let
  fail =
    code: path: detail:
    throw "${code}: ${path}: ${detail}";
  requireEqual =
    code: path: expected: observed:
    if expected == observed then
      true
    else
      fail code path "expected ${builtins.toJSON expected}, observed ${builtins.toJSON observed}";
  requireString =
    code: path: value:
    if builtins.isString value && value != "" then
      value
    else
      fail code path "expected non-empty string";
in
{
  inherit
    repository
    repositoryRevision
    stageIndex
    previousStage
    nextStage
    normalInputContract
    ;

  acknowledge =
    {
      traceId,
      declaredRepository,
      lockedRepositoryRevision,
      declaredStageIndex,
      declaredNormalInputContract,
      replacementContract,
      expectedReplacementContract,
      declaredFirstActiveBoundary,
      expectedFirstActiveBoundary,
      reason,
      declaredPreviousStage,
      declaredNextStage,
      replacementIdentity,
      replacementDigest,
      acknowledgedReplacementDigest ? replacementDigest,
      payloadAccessed ? false,
      transformationStarted ? false,
      acknowledgementCount ? 1,
    }:
    let
      _trace = requireString "NS_SKIP_IDENTITY_MISMATCH" "/traceId" traceId;
      _repository = requireEqual "NS_SKIP_IDENTITY_MISMATCH" "/repository" repository declaredRepository;
      _revision =
        requireEqual "NS_SKIP_IDENTITY_MISMATCH" "/repositoryRevision" repositoryRevision
          lockedRepositoryRevision;
      _index = requireEqual "NS_SKIP_IDENTITY_MISMATCH" "/stageIndex" stageIndex declaredStageIndex;
      _normalContract =
        requireEqual "NS_SKIP_BOUNDARY_MISMATCH" "/normalInputContract" normalInputContract
          declaredNormalInputContract;
      _replacementContract =
        requireEqual "NS_SKIP_BOUNDARY_MISMATCH" "/replacementContract" expectedReplacementContract
          replacementContract;
      _boundary =
        requireEqual "NS_SKIP_BOUNDARY_MISMATCH" "/firstActiveBoundary" expectedFirstActiveBoundary
          declaredFirstActiveBoundary;
      _digest =
        requireEqual "NS_SKIP_DIGEST_MUTATED" "/replacementDigest" replacementDigest
          acknowledgedReplacementDigest;
      _payload = requireEqual "NS_SKIP_PAYLOAD_ACCESSED" "/payloadAccessed" false payloadAccessed;
      _transformation =
        requireEqual "NS_SKIP_TRANSFORMATION_STARTED" "/transformationStarted" false
          transformationStarted;
      _count = requireEqual "NS_SKIP_ACK_DUPLICATE" "/acknowledgementCount" 1 acknowledgementCount;
      _previous =
        requireEqual "NS_SKIP_NEXT_STAGE_INVALID" "/previousStage" previousStage
          declaredPreviousStage;
      _next = requireEqual "NS_SKIP_NEXT_STAGE_INVALID" "/nextStage" nextStage declaredNextStage;
      acknowledgement = {
        kind = "controlled-skip-acknowledgement";
        schemaRevision = "network-controlled-skip/v1";
        inherit
          traceId
          repository
          repositoryRevision
          stageIndex
          normalInputContract
          replacementContract
          declaredFirstActiveBoundary
          reason
          previousStage
          nextStage
          replacementIdentity
          replacementDigest
          ;
        payloadAccessed = false;
        transformationStarted = false;
        acknowledgementCount = 1;
      };
    in
    builtins.deepSeq
      [
        _trace
        _repository
        _revision
        _index
        _normalContract
        _replacementContract
        _boundary
        _digest
        _payload
        _transformation
        _count
        _previous
        _next
      ]
      (
        acknowledgement
        // {
          acknowledgementDigest = builtins.hashString "sha256" (builtins.toJSON acknowledgement);
        }
      );
}
