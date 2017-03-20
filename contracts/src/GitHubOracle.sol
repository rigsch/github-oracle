pragma solidity ^0.4.8;

/**
 * Contract that oracle github API
 * 
 * GitHubOracle register users and create GitHubToken contracts
 * Registration requires user create a gist with only their account address
 * GitHubOracle will create one GitHubToken contract per repository
 * GitHubToken mint tokens by commit only for registered users in GitHubOracle
 * GitHubToken is a LockableCoin, that accept donatations and can be withdrawn by Token Holders
 * The lookups are done by Oraclize that charge a small fee
 * The contract itself will never charge any fee
 * 
 * By Ricardo Guilherme Schmidt
 * Released under GPLv3 License
 */
 
import "lib/StringLib.sol";
import "lib/JSONLib.sol";

import "lib/oraclize/oraclizeAPI_0.4.sol";
import "lib/ethereans/management/Owned.sol";
import "./git-repository/GitRepositoryFactoryI.sol";
import "./storage/GitHubOracleStorageI.sol";



contract GitHubOracle is Owned, usingOraclize {

    using StringLib for string;

    GitRepositoryFactoryI public gitRepositoryFactoryI;
    GitHubOracleStorageI public db;

    enum OracleType { SET_REPOSITORY, SET_USER, CLAIM_COMMIT, UPDATE_ISSUE }
    mapping (bytes32 => OracleType) claimType; //temporary db enumerating oraclize calls
    mapping (bytes32 => CommitClaim) commitClaim; //temporary db for oraclize commit token claim calls
    mapping (bytes32 => UserClaim) userClaim; //temporary db for oraclize user register queries

    string private credentials = ""; //store encrypted values of api access credentials
    
    //stores temporary data for oraclize user register request
    struct UserClaim {
        address sender;
        string githubid;
    }
    //stores temporary data for oraclize repository commit claim
    struct CommitClaim {
        string repository;
        string commitid;
    }
    
    function GitHubOracle(GitHubOracleStorageI _db, GitRepositoryFactoryI _gitRepositoryFactoryI){ //
       gitRepositoryFactoryI = _gitRepositoryFactoryI;
       db = _db;
    }
    
    //register or change a github user ethereum address 100000000000000000
    function register(string _github_user, string _gistid)
     payable {
        bytes32 ocid = oraclize_query("nested", StringLib.concat("[identity] ${[URL] https://gist.githubusercontent.com/",_github_user,"/",_gistid,"/raw/}, ${[URL] json(https://api.github.com/gists/").concat(_gistid,credentials,").owner.[id,login]}"));
        claimType[ocid] = OracleType.SET_USER;
        userClaim[ocid] = UserClaim({sender: msg.sender, githubid: _github_user});
    }
    
    function claimCommit(string _repository, string _commitid)
     payable {
        bytes32 ocid = oraclize_query("URL", StringLib.concat("json(https://api.github.com/repos/",_repository,"/commits/", _commitid, credentials).concat(").[author,stats].[id,total]"));
        claimType[ocid] = OracleType.CLAIM_COMMIT;
        commitClaim[ocid] = CommitClaim( { repository: _repository, commitid:_commitid});
    }
    
    function addRepository(string _repository)
     payable {
        bytes32 ocid = oraclize_query("URL", StringLib.concat("json(https://api.github.com/repos/",_repository,credentials,").$.id,full_name,watchers,subscribers_count"),4000000);
        claimType[ocid] = OracleType.SET_REPOSITORY;
    }  
    
    function setAPICredentials(string _client_id, string _client_secret)
     only_owner {
         credentials = StringLib.concat("?client_id=${[decrypt] ", _client_id,"}&client_secret=${[decrypt] ", _client_secret,"}");
    }
    
    function clearAPICredentials()
     only_owner {
         credentials = "";
     }


    event OracleEvent(bytes32 myid, string result, bytes proof);
    //oraclize response callback

    function __callback(bytes32 myid, string result, bytes proof) {
        OracleEvent(myid,result,proof);
        if (msg.sender != oraclize.cbAddress()){
          throw;  
        }else if(claimType[myid]==OracleType.SET_USER){
            _register(myid, result);
        }else if(claimType[myid]==OracleType.CLAIM_COMMIT){ 
            _claimCommit(myid, result);
        }else if(claimType[myid] == OracleType.SET_REPOSITORY){
            _setRepository(myid, result);
        }
        delete claimType[myid];  //should always be deleted
    }

    event UserSet(string githubLogin);
    function _register(bytes32 myid, string result) 
     internal {
        uint256 userId; string memory login; address addrLoaded; 
        uint8 utype; //TODO
        bytes memory v = bytes(result);
        uint8 pos = 0;
        (addrLoaded,pos) = JSONLib.getNextAddr(v,pos);
        (userId,pos) = JSONLib.getNextUInt(v,pos);
        (login,pos) = JSONLib.getNextString(v,pos);
        if(userClaim[myid].sender == addrLoaded && userClaim[myid].githubid.compare(login) == 0){
            UserSet(login); 
            db.addUser(userId, login, utype, addrLoaded);
        } //TODO: update user login and address;
        delete userClaim[myid]; //should always be deleted
    }
    
    event GitRepositoryRegistered(uint256 projectId, string full_name, uint256 watchers, uint256 subscribers);    
    function _setRepository(bytes32 myid, string result) //[83725290, "ethereans/github-token", 4, 2]
      {
        uint256 projectId; string memory full_name; uint256 watchers; uint256 subscribers; 
        uint256 ownerId; string memory name; //TODO
        bytes memory v = bytes(result);
        uint8 pos = 0;
        (projectId,pos) = JSONLib.getNextUInt(v,pos);
        (full_name,pos) = JSONLib.getNextString(v,pos);
        (watchers,pos) = JSONLib.getNextUInt(v,pos);
        (subscribers,pos) = JSONLib.getNextUInt(v,pos);
        address repository = db.getRepositoryAddress(projectId);
        if(repository == 0x0){
            GitRepositoryRegistered(projectId,full_name,watchers,subscribers);
            repository = gitRepositoryFactoryI.newGitRepository(projectId,full_name);
            db.addRepository(projectId,ownerId,name,full_name,repository);
        }
        GitRepositoryI(repository).setStats(subscribers,watchers);
    }

    event NewClaim(string repository, string commitid, uint userid, uint total );
    function _claimCommit(bytes32 myid, string result)
     internal {
        uint256 total; uint256 userId;
        bytes memory v = bytes(result);
        uint8 pos = 0;
        (userId,pos) = JSONLib.getNextUInt(v,pos);
		(total,pos) = JSONLib.getNextUInt(v,pos);
		NewClaim(commitClaim[myid].repository,commitClaim[myid].commitid,userId,total);
		GitRepositoryI repository = GitRepositoryI(db.getRepositoryAddress(commitClaim[myid].repository));
		repository.claim(commitClaim[myid].commitid.parseBytes20(), db.getUserAddress(userId), total);
        delete commitClaim[myid]; //should always be deleted
    }


}